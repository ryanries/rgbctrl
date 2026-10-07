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
const access_violation: u32 = 0xC0000005;

const Operation = enum {
    initialize,
    device_handle,
    fan_count,
    device_name,
    fan_rpm,
    temperature,
    utilization,
    power,
    graphics_clock,
    memory_clock,
    memory_info,
    shutdown,

    fn name(self: Operation) []const u8 {
        return switch (self) {
            .initialize => "nvmlInit_v2",
            .device_handle => "nvmlDeviceGetHandleByIndex_v2",
            .fan_count => "nvmlDeviceGetNumFans",
            .device_name => "nvmlDeviceGetName",
            .fan_rpm => "nvmlDeviceGetFanSpeedRPM",
            .temperature => "nvmlDeviceGetTemperature",
            .utilization => "nvmlDeviceGetUtilizationRates",
            .power => "nvmlDeviceGetPowerUsage",
            .graphics_clock => "nvmlDeviceGetClockInfo(graphics)",
            .memory_clock => "nvmlDeviceGetClockInfo(memory)",
            .memory_info => "nvmlDeviceGetMemoryInfo",
            .shutdown => "nvmlShutdown",
        };
    }
};

const NvmlFault = struct {
    operation: Operation,
    exception_code: u32,
};

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
const GuardThunk = *const fn (context: ?*anyopaque) callconv(.c) i32;

const GuardedResult = union(enum) {
    completed: i32,
    fault: u32,
};

const GuardInvoker = *const fn (thunk: GuardThunk, context: ?*anyopaque) GuardedResult;

const LoadLibraryFn = *const fn (name: [*:0]const u16, file: ?win32.HANDLE, flags: u32) callconv(.winapi) ?win32.HMODULE;
const GetProcAddressFn = *const fn (module: win32.HMODULE, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
const FreeLibraryFn = *const fn (module: win32.HMODULE) callconv(.winapi) win32.BOOL;

const PlatformOperations = struct {
    load_library_ex_w: LoadLibraryFn = win32.LoadLibraryExW,
    get_proc_address: GetProcAddressFn = win32.GetProcAddress,
    free_library: FreeLibraryFn = win32.FreeLibrary,
};

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

extern fn rgbctrl_nvml_guard(
    thunk: GuardThunk,
    context: ?*anyopaque,
    status: *i32,
    exception_code: *u32,
) callconv(.c) i32;

fn invokeWithSeh(thunk: GuardThunk, context: ?*anyopaque) GuardedResult {
    var status: i32 = nvml_success;
    var exception_code: u32 = 0;
    if (rgbctrl_nvml_guard(thunk, context, &status, &exception_code) != 0) return .{ .completed = status };
    return .{ .fault = exception_code };
}

fn guardedCallWith(
    invoker: GuardInvoker,
    function: anytype,
    arguments: std.meta.ArgsTuple(@typeInfo(@TypeOf(function)).pointer.child),
) GuardedResult {
    const Function = @TypeOf(function);
    const Arguments = @TypeOf(arguments);
    const Call = struct {
        function: Function,
        arguments: Arguments,

        fn invoke(context: ?*anyopaque) callconv(.c) i32 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            return @call(.auto, self.function, self.arguments);
        }
    };
    var context = Call{ .function = function, .arguments = arguments };
    return invoker(Call.invoke, &context);
}

fn guardedCall(
    function: anytype,
    arguments: std.meta.ArgsTuple(@typeInfo(@TypeOf(function)).pointer.child),
) GuardedResult {
    const invoker = if (builtin.is_test) guarded_invoker else invokeWithSeh;
    return guardedCallWith(invoker, function, arguments);
}

var guarded_invoker: GuardInvoker = invokeWithSeh;
var platform_operations = PlatformOperations{};

fn loadNvml() ?win32.HMODULE {
    const load_library = if (builtin.is_test) platform_operations.load_library_ex_w else win32.LoadLibraryExW;
    return load_library(win32.L("nvml.dll"), null, win32.LOAD_LIBRARY_SEARCH_SYSTEM32);
}

fn symbol(comptime T: type, module: win32.HMODULE, name: [*:0]const u8) ?T {
    const get_proc_address = if (builtin.is_test) platform_operations.get_proc_address else win32.GetProcAddress;
    const address = get_proc_address(module, name) orelse return null;
    return @ptrCast(address);
}

fn freeNvmlModule(module: win32.HMODULE) void {
    const free_library = if (builtin.is_test) platform_operations.free_library else win32.FreeLibrary;
    _ = free_library(module);
}

fn vramLoadPercent(memory: Memory) ?f64 {
    if (memory.total == 0) return null;
    const used = @min(memory.used, memory.total);
    return @as(f64, @floatFromInt(used)) * 100.0 / @as(f64, @floatFromInt(memory.total));
}

fn recordNvmlFault(host: sdk.HostApi, operation: Operation, exception_code: u32) void {
    if (nvml_fault != null) return;
    nvml_fault = .{ .operation = operation, .exception_code = exception_code };
    host.err(
        "NVML access violation in {s} (0x{X:0>8}); NVIDIA GPU sensors are disabled until rgbctrl restarts.",
        .{ operation.name(), exception_code },
    );
}

fn completedStatus(host: sdk.HostApi, operation: Operation, result: GuardedResult) ?i32 {
    return switch (result) {
        .completed => |status| status,
        .fault => |exception_code| {
            recordNvmlFault(host, operation, exception_code);
            return null;
        },
    };
}

fn shutdownAndFree(host: sdk.HostApi, module: win32.HMODULE, shutdown: StatusFn) bool {
    _ = completedStatus(host, .shutdown, guardedCall(shutdown, .{})) orelse return false;
    freeNvmlModule(module);
    return true;
}

const Instance = struct {
    host: sdk.HostApi,
    module: ?win32.HMODULE = null,
    api: ?Api = null,
    device: ?NvmlDevice = null,
    fan_count: u32 = 1,
    failed: [sensor_names.len]bool = @splat(false),

    fn load(self: *Instance) bool {
        const module = loadNvml() orelse {
            self.host.info("nvml.dll not found (no NVIDIA driver); GPU sensors are unavailable", .{});
            return true;
        };
        const initialize = symbol(StatusFn, module, "nvmlInit_v2");
        const shutdown = symbol(StatusFn, module, "nvmlShutdown");
        const get_handle = symbol(HandleFn, module, "nvmlDeviceGetHandleByIndex_v2");
        if (initialize == null or shutdown == null or get_handle == null) {
            self.host.warn("nvml.dll lacks nvmlInit_v2, nvmlShutdown or nvmlDeviceGetHandleByIndex_v2; GPU sensors are unavailable", .{});
            freeNvmlModule(module);
            return true;
        }
        const init_status = completedStatus(self.host, .initialize, guardedCall(initialize.?, .{})) orelse return false;
        if (init_status != nvml_success) {
            self.host.warn("nvmlInit_v2 failed (NVML error {d}); GPU sensors are unavailable", .{init_status});
            freeNvmlModule(module);
            return true;
        }
        var device: ?NvmlDevice = null;
        const handle_status = completedStatus(self.host, .device_handle, guardedCall(get_handle.?, .{ 0, &device })) orelse return false;
        if (handle_status != nvml_success or device == null) {
            self.host.info("NVML found no GPU (NVML error {d}); GPU sensors are unavailable", .{handle_status});
            return shutdownAndFree(self.host, module, shutdown.?);
        }
        const nvml_device = device.?;
        self.module = module;
        self.device = nvml_device;
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
            const status = completedStatus(self.host, .fan_count, guardedCall(get_fan_count, .{ nvml_device, &count })) orelse return false;
            if (status == nvml_success and count > 0) self.fan_count = @min(count, max_fans);
        }
        if (symbol(NameFn, module, "nvmlDeviceGetName")) |get_name| {
            var name: [96]u8 = @splat(0);
            const status = completedStatus(self.host, .device_name, guardedCall(get_name, .{ nvml_device, &name, name.len })) orelse return false;
            if (status == nvml_success) self.host.debug("reading the sensors of {s} ({d} fans)", .{ std.mem.sliceTo(&name, 0), self.fan_count });
        }
        return true;
    }

    fn unload(self: *Instance) void {
        var shutdown_completed = nvml_fault == null;
        if (shutdown_completed) {
            if (self.api) |api| {
                shutdown_completed = completedStatus(self.host, .shutdown, guardedCall(api.shutdown, .{})) != null;
            }
        }
        if (shutdown_completed) {
            if (self.module) |module| freeNvmlModule(module);
        }
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

    fn publishFan(self: *Instance, api: Api, device: NvmlDevice) bool {
        const get_rpm = api.fan_rpm orelse return true;
        var highest: u32 = 0;
        var status: i32 = nvml_error_not_supported;
        var fan: u32 = 0;
        while (fan < self.fan_count) : (fan += 1) {
            var info = FanSpeedInfo{ .version = fan_speed_info_v1, .fan = fan, .speed = 0 };
            const fan_status = completedStatus(self.host, .fan_rpm, guardedCall(get_rpm, .{ device, &info })) orelse return false;
            if (fan_status == nvml_success) {
                status = nvml_success;
                highest = @max(highest, info.speed);
            } else if (status != nvml_success) {
                status = fan_status;
            }
        }
        self.publish(.fan, status, @floatFromInt(highest));
        return true;
    }

    fn sample(self: *Instance) bool {
        const api = self.api orelse return true;
        const device = self.device orelse return true;
        var value: u32 = 0;
        if (api.temperature) |get| {
            const status = completedStatus(self.host, .temperature, guardedCall(get, .{ device, temperature_gpu, &value })) orelse return false;
            self.publish(.temp, status, @floatFromInt(value));
        }
        if (api.utilization) |get| {
            var utilization = Utilization{ .gpu = 0, .memory = 0 };
            const status = completedStatus(self.host, .utilization, guardedCall(get, .{ device, &utilization })) orelse return false;
            self.publish(.load, status, @floatFromInt(@min(utilization.gpu, 100)));
        }
        if (api.power) |get| {
            const status = completedStatus(self.host, .power, guardedCall(get, .{ device, &value })) orelse return false;
            self.publish(.power, status, @as(f64, @floatFromInt(value)) / 1000.0);
        }
        if (!self.publishFan(api, device)) return false;
        if (api.clock) |get| {
            const graphics_status = completedStatus(self.host, .graphics_clock, guardedCall(get, .{ device, clock_graphics, &value })) orelse return false;
            self.publish(.freq, graphics_status, @floatFromInt(value));
            const memory_status = completedStatus(self.host, .memory_clock, guardedCall(get, .{ device, clock_memory, &value })) orelse return false;
            self.publish(.mem_freq, memory_status, @floatFromInt(value));
        }
        if (api.memory) |get| {
            var memory = Memory{ .total = 0, .free = 0, .used = 0 };
            const status = completedStatus(self.host, .memory_info, guardedCall(get, .{ device, &memory })) orelse return false;
            const percent = vramLoadPercent(memory);
            self.publish(.mem_load, if (status == nvml_success and percent == null) nvml_error_not_supported else status, percent orelse 0);
        }
        return true;
    }
};

var nvml_fault: ?NvmlFault = null;
var panic_host: ?*const abi.Host = null;
var live_instances: usize = 0;

fn reportPanic(message: []const u8) void {
    const host = panic_host orelse return;
    host.log(host.ctx, @intFromEnum(abi.LogLevel.err), message.ptr, message.len);
}

fn instanceFrom(pointer: ?*anyopaque) *Instance {
    return @ptrCast(@alignCast(pointer.?));
}

fn createInstance() ?*Instance {
    const instance = std.heap.page_allocator.create(Instance) catch return null;
    if (builtin.is_test) live_instances += 1;
    return instance;
}

fn destroyInstance(instance: *Instance) void {
    if (builtin.is_test) {
        std.debug.assert(live_instances > 0);
        live_instances -= 1;
    }
    std.heap.page_allocator.destroy(instance);
}

fn open(host: *const abi.Host, config: ?*const abi.Json, instance_out: *?*anyopaque) callconv(.c) i32 {
    _ = config;
    instance_out.* = null;
    if (nvml_fault != null) return abi.status_fail;
    panic_host = host;
    sdk.panic.hook = reportPanic;
    const self = createInstance() orelse return abi.status_fail;
    self.* = .{ .host = .{ .host = host } };
    if (!self.load()) {
        destroyInstance(self);
        return abi.status_fail;
    }
    instance_out.* = self;
    return abi.status_ok;
}

fn close(pointer: ?*anyopaque, reason: u32) callconv(.c) void {
    _ = reason;
    const self = instanceFrom(pointer);
    self.unload();
    destroyInstance(self);
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
    if (nvml_fault != null) return abi.status_fail;
    return if (instanceFrom(pointer).sample()) abi.status_ok else abi.status_fail;
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

pub const testing = if (builtin.is_test) struct {
    pub const Result = GuardedResult;
    pub const KindValueFunction = *const fn (device: *anyopaque, kind: u32, value: *u32) callconv(.c) i32;

    pub fn guardedKindValue(function: KindValueFunction, device: *anyopaque, kind: u32, value: *u32) Result {
        return guardedCallWith(invokeWithSeh, function, .{ device, kind, value });
    }
} else struct {};

const TestHostState = struct {
    log_count: usize = 0,
    fault_log_count: usize = 0,
    last_fault_log: [256]u8 = @splat(0),
    last_fault_log_length: usize = 0,
    sensor_set_count: usize = 0,
    published_sensors: [sensor_names.len]bool = @splat(false),

    fn fromContext(context: ?*anyopaque) *TestHostState {
        return @ptrCast(@alignCast(context.?));
    }

    fn log(context: ?*anyopaque, level: u32, message: ?[*]const u8, message_length: usize) callconv(.c) void {
        _ = level;
        const self = fromContext(context);
        self.log_count += 1;
        const message_pointer = message orelse return;
        const message_slice = message_pointer[0..message_length];
        if (!std.mem.startsWith(u8, message_slice, "NVML access violation in ")) return;
        const copy_length = @min(message_slice.len, self.last_fault_log.len);
        @memcpy(self.last_fault_log[0..copy_length], message_slice[0..copy_length]);
        self.last_fault_log_length = copy_length;
        self.fault_log_count += 1;
    }

    fn nowMs(context: ?*anyopaque) callconv(.c) u64 {
        _ = context;
        return 0;
    }

    fn setSensor(context: ?*anyopaque, name: ?[*]const u8, name_length: usize, value: f64) callconv(.c) void {
        _ = value;
        const self = fromContext(context);
        self.sensor_set_count += 1;
        const name_pointer = name orelse return;
        const name_slice = name_pointer[0..name_length];
        for (sensor_names, 0..) |sensor_name, index| {
            if (std.mem.eql(u8, name_slice, sensor_name)) self.published_sensors[index] = true;
        }
    }

    fn getSensor(context: ?*anyopaque, name: ?[*]const u8, name_length: usize, value: ?*f64, age_ms: ?*u64) callconv(.c) i32 {
        _ = context;
        _ = name;
        _ = name_length;
        _ = value;
        _ = age_ms;
        return abi.status_fail;
    }

    fn jsonType(context: ?*anyopaque, node: ?*const abi.Json) callconv(.c) u32 {
        _ = context;
        _ = node;
        return 0;
    }

    fn jsonGet(context: ?*anyopaque, object: ?*const abi.Json, key: ?[*]const u8, key_length: usize) callconv(.c) ?*const abi.Json {
        _ = context;
        _ = object;
        _ = key;
        _ = key_length;
        return null;
    }

    fn jsonLength(context: ?*anyopaque, node: ?*const abi.Json) callconv(.c) u32 {
        _ = context;
        _ = node;
        return 0;
    }

    fn jsonAt(context: ?*anyopaque, array: ?*const abi.Json, index: u32) callconv(.c) ?*const abi.Json {
        _ = context;
        _ = array;
        _ = index;
        return null;
    }

    fn jsonMember(context: ?*anyopaque, object: ?*const abi.Json, index: u32, key: ?*?[*]const u8, key_length: ?*usize) callconv(.c) ?*const abi.Json {
        _ = context;
        _ = object;
        _ = index;
        _ = key;
        _ = key_length;
        return null;
    }

    fn jsonNumber(context: ?*anyopaque, node: ?*const abi.Json, value: ?*f64) callconv(.c) i32 {
        _ = context;
        _ = node;
        _ = value;
        return abi.status_fail;
    }

    fn jsonBool(context: ?*anyopaque, node: ?*const abi.Json, value: ?*i32) callconv(.c) i32 {
        _ = context;
        _ = node;
        _ = value;
        return abi.status_fail;
    }

    fn jsonString(context: ?*anyopaque, node: ?*const abi.Json, text: ?*?[*]const u8, text_length: ?*usize) callconv(.c) i32 {
        _ = context;
        _ = node;
        _ = text;
        _ = text_length;
        return abi.status_fail;
    }

    fn host(self: *TestHostState) abi.Host {
        return .{
            .struct_size = @sizeOf(abi.Host),
            .abi_version = abi.abi_version,
            .ctx = self,
            .host_dir = null,
            .mode = 0,
            .reserved = 0,
            .log = log,
            .now_ms = nowMs,
            .sensor_set = setSensor,
            .sensor_get = getSensor,
            .json_type = jsonType,
            .json_get = jsonGet,
            .json_len = jsonLength,
            .json_at = jsonAt,
            .json_member = jsonMember,
            .json_number = jsonNumber,
            .json_bool = jsonBool,
            .json_string = jsonString,
        };
    }
};

const TestPlatformRecorder = struct {
    load_calls: usize = 0,
    get_proc_address_calls: usize = 0,
    free_calls: usize = 0,
    name: [32]u16 = @splat(0),
    name_length: usize = 0,
    file: ?win32.HANDLE = null,
    flags: u32 = 0,
    load_result: ?win32.HMODULE = null,
    invalid_module: bool = false,
    missing_symbol: ?[]const u8 = null,
};

const TestNvmlState = struct {
    initialize_status: i32 = nvml_success,
    handle_status: i32 = nvml_success,
    fan_count_status: i32 = nvml_success,
    name_status: i32 = nvml_success,
    temperature_status: i32 = nvml_success,
    utilization_status: i32 = nvml_success,
    power_status: i32 = nvml_success,
    fan_rpm_status: i32 = nvml_success,
    clock_status: i32 = nvml_success,
    memory_status: i32 = nvml_success,
    shutdown_status: i32 = nvml_success,
    initialize_calls: usize = 0,
    handle_calls: usize = 0,
    fan_count_calls: usize = 0,
    name_calls: usize = 0,
    temperature_calls: usize = 0,
    utilization_calls: usize = 0,
    power_calls: usize = 0,
    fan_rpm_calls: usize = 0,
    clock_calls: usize = 0,
    memory_calls: usize = 0,
    shutdown_calls: usize = 0,
    fan_count: u32 = 1,
};

const TestGuardScript = struct {
    invocation_count: usize = 0,
    fault_on_call: ?usize = null,
    exception_code: u32 = access_violation,
};

const test_module: win32.HMODULE = @ptrFromInt(0x1000);
const test_device: NvmlDevice = @ptrFromInt(0x2000);

var test_platform_recorder = TestPlatformRecorder{};
var test_nvml_state = TestNvmlState{};
var test_guard_script = TestGuardScript{};

fn recordLoadLibrary(name: [*:0]const u16, file: ?win32.HANDLE, flags: u32) callconv(.winapi) ?win32.HMODULE {
    const name_slice = std.mem.span(name);
    const copy_length = @min(name_slice.len, test_platform_recorder.name.len);
    @memcpy(test_platform_recorder.name[0..copy_length], name_slice[0..copy_length]);
    test_platform_recorder.load_calls += 1;
    test_platform_recorder.name_length = copy_length;
    test_platform_recorder.file = file;
    test_platform_recorder.flags = flags;
    return test_platform_recorder.load_result;
}

fn recordGetProcAddress(module: win32.HMODULE, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque {
    test_platform_recorder.get_proc_address_calls += 1;
    if (module != test_module) test_platform_recorder.invalid_module = true;
    const symbol_name = std.mem.span(name);
    if (test_platform_recorder.missing_symbol) |missing_symbol| {
        if (std.mem.eql(u8, symbol_name, missing_symbol)) return null;
    }
    if (std.mem.eql(u8, symbol_name, "nvmlInit_v2")) return @ptrCast(&testNvmlInitialize);
    if (std.mem.eql(u8, symbol_name, "nvmlShutdown")) return @ptrCast(&testNvmlShutdown);
    if (std.mem.eql(u8, symbol_name, "nvmlDeviceGetHandleByIndex_v2")) return @ptrCast(&testNvmlGetHandle);
    if (std.mem.eql(u8, symbol_name, "nvmlDeviceGetTemperature")) return @ptrCast(&testNvmlGetTemperature);
    if (std.mem.eql(u8, symbol_name, "nvmlDeviceGetUtilizationRates")) return @ptrCast(&testNvmlGetUtilization);
    if (std.mem.eql(u8, symbol_name, "nvmlDeviceGetPowerUsage")) return @ptrCast(&testNvmlGetPower);
    if (std.mem.eql(u8, symbol_name, "nvmlDeviceGetClockInfo")) return @ptrCast(&testNvmlGetClock);
    if (std.mem.eql(u8, symbol_name, "nvmlDeviceGetMemoryInfo")) return @ptrCast(&testNvmlGetMemory);
    if (std.mem.eql(u8, symbol_name, "nvmlDeviceGetFanSpeedRPM")) return @ptrCast(&testNvmlGetFanRpm);
    if (std.mem.eql(u8, symbol_name, "nvmlDeviceGetNumFans")) return @ptrCast(&testNvmlGetFanCount);
    if (std.mem.eql(u8, symbol_name, "nvmlDeviceGetName")) return @ptrCast(&testNvmlGetName);
    return null;
}

fn recordFreeLibrary(module: win32.HMODULE) callconv(.winapi) win32.BOOL {
    if (module != test_module) test_platform_recorder.invalid_module = true;
    test_platform_recorder.free_calls += 1;
    return 1;
}

fn testNvmlInitialize() callconv(.c) i32 {
    test_nvml_state.initialize_calls += 1;
    return test_nvml_state.initialize_status;
}

fn testNvmlShutdown() callconv(.c) i32 {
    test_nvml_state.shutdown_calls += 1;
    return test_nvml_state.shutdown_status;
}

fn testNvmlGetHandle(index: u32, device: *?NvmlDevice) callconv(.c) i32 {
    _ = index;
    test_nvml_state.handle_calls += 1;
    device.* = if (test_nvml_state.handle_status == nvml_success) test_device else null;
    return test_nvml_state.handle_status;
}

fn testNvmlGetFanCount(device: NvmlDevice, count: *u32) callconv(.c) i32 {
    _ = device;
    test_nvml_state.fan_count_calls += 1;
    count.* = test_nvml_state.fan_count;
    return test_nvml_state.fan_count_status;
}

fn testNvmlGetName(device: NvmlDevice, name: [*]u8, length: u32) callconv(.c) i32 {
    _ = device;
    test_nvml_state.name_calls += 1;
    const test_name = "Test NVIDIA GPU";
    if (length > test_name.len) {
        @memcpy(name[0..test_name.len], test_name);
        name[test_name.len] = 0;
    }
    return test_nvml_state.name_status;
}

fn testNvmlGetTemperature(device: NvmlDevice, kind: u32, value: *u32) callconv(.c) i32 {
    _ = device;
    _ = kind;
    test_nvml_state.temperature_calls += 1;
    value.* = 61;
    return test_nvml_state.temperature_status;
}

fn testNvmlGetUtilization(device: NvmlDevice, utilization: *Utilization) callconv(.c) i32 {
    _ = device;
    test_nvml_state.utilization_calls += 1;
    utilization.* = .{ .gpu = 72, .memory = 34 };
    return test_nvml_state.utilization_status;
}

fn testNvmlGetPower(device: NvmlDevice, value: *u32) callconv(.c) i32 {
    _ = device;
    test_nvml_state.power_calls += 1;
    value.* = 125000;
    return test_nvml_state.power_status;
}

fn testNvmlGetFanRpm(device: NvmlDevice, info: *FanSpeedInfo) callconv(.c) i32 {
    _ = device;
    test_nvml_state.fan_rpm_calls += 1;
    info.speed = 1455;
    return test_nvml_state.fan_rpm_status;
}

fn testNvmlGetClock(device: NvmlDevice, kind: u32, value: *u32) callconv(.c) i32 {
    _ = device;
    test_nvml_state.clock_calls += 1;
    value.* = if (kind == clock_graphics) 2610 else 14001;
    return test_nvml_state.clock_status;
}

fn testNvmlGetMemory(device: NvmlDevice, memory: *Memory) callconv(.c) i32 {
    _ = device;
    test_nvml_state.memory_calls += 1;
    memory.* = .{ .total = 16 << 30, .free = 12 << 30, .used = 4 << 30 };
    return test_nvml_state.memory_status;
}

fn invokeScripted(thunk: GuardThunk, context: ?*anyopaque) GuardedResult {
    test_guard_script.invocation_count += 1;
    if (test_guard_script.fault_on_call) |fault_call| {
        if (fault_call == test_guard_script.invocation_count) return .{ .fault = test_guard_script.exception_code };
    }
    return .{ .completed = thunk(context) };
}

fn testPanicHook(message: []const u8) void {
    _ = message;
}

const TestEnvironment = struct {
    previous_fault: ?NvmlFault,
    previous_panic_host: ?*const abi.Host,
    previous_panic_hook: ?sdk.panic.Hook,
    previous_live_instances: usize,
    previous_guarded_invoker: GuardInvoker,
    previous_platform_operations: PlatformOperations,
    previous_platform_recorder: TestPlatformRecorder,
    previous_nvml_state: TestNvmlState,
    previous_guard_script: TestGuardScript,

    fn init() TestEnvironment {
        const environment = TestEnvironment{
            .previous_fault = nvml_fault,
            .previous_panic_host = panic_host,
            .previous_panic_hook = sdk.panic.hook,
            .previous_live_instances = live_instances,
            .previous_guarded_invoker = guarded_invoker,
            .previous_platform_operations = platform_operations,
            .previous_platform_recorder = test_platform_recorder,
            .previous_nvml_state = test_nvml_state,
            .previous_guard_script = test_guard_script,
        };
        nvml_fault = null;
        test_platform_recorder = .{ .load_result = test_module };
        test_nvml_state = .{};
        test_guard_script = .{};
        guarded_invoker = invokeScripted;
        platform_operations = .{
            .load_library_ex_w = recordLoadLibrary,
            .get_proc_address = recordGetProcAddress,
            .free_library = recordFreeLibrary,
        };
        return environment;
    }

    fn deinit(self: TestEnvironment) void {
        std.debug.assert(live_instances == self.previous_live_instances);
        std.debug.assert(!test_platform_recorder.invalid_module);
        nvml_fault = self.previous_fault;
        panic_host = self.previous_panic_host;
        sdk.panic.hook = self.previous_panic_hook;
        live_instances = self.previous_live_instances;
        guarded_invoker = self.previous_guarded_invoker;
        platform_operations = self.previous_platform_operations;
        test_platform_recorder = self.previous_platform_recorder;
        test_nvml_state = self.previous_nvml_state;
        test_guard_script = self.previous_guard_script;
    }
};

fn expectOpenFault(fault_call: usize, operation: Operation) !void {
    const environment = TestEnvironment.init();
    defer environment.deinit();

    test_guard_script.fault_on_call = fault_call;
    var host_state = TestHostState{};
    var host = host_state.host();
    var instance: ?*anyopaque = null;
    const status = open(&host, null, &instance);
    defer if (instance) |pointer| close(pointer, 0);

    try std.testing.expectEqual(abi.status_fail, status);
    try std.testing.expectEqual(@as(?*anyopaque, null), instance);
    try std.testing.expectEqual(@as(?NvmlFault, .{ .operation = operation, .exception_code = access_violation }), nvml_fault);
    try std.testing.expectEqual(fault_call, test_guard_script.invocation_count);
    try std.testing.expectEqual(@as(usize, 0), test_nvml_state.shutdown_calls);
    try std.testing.expectEqual(@as(usize, 0), test_platform_recorder.free_calls);
    try std.testing.expectEqual(@as(usize, 0), live_instances);
    try std.testing.expectEqual(@as(usize, 1), host_state.fault_log_count);
}

fn expectSampleFault(fault_call: usize, operation: Operation) !void {
    const environment = TestEnvironment.init();
    defer environment.deinit();

    var host_state = TestHostState{};
    var host = host_state.host();
    var instance: ?*anyopaque = null;
    try std.testing.expectEqual(abi.status_ok, open(&host, null, &instance));
    defer if (instance) |pointer| close(pointer, 0);

    test_guard_script = .{ .fault_on_call = fault_call };
    try std.testing.expectEqual(abi.status_fail, tick(instance, 0));
    try std.testing.expectEqual(@as(?NvmlFault, .{ .operation = operation, .exception_code = access_violation }), nvml_fault);
    try std.testing.expectEqual(fault_call, test_guard_script.invocation_count);
    try std.testing.expectEqual(@as(usize, 1), host_state.fault_log_count);
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

test "test seams default to the production guard and platform functions" {
    try std.testing.expectEqual(@intFromPtr(&invokeWithSeh), @intFromPtr(guarded_invoker));
    try std.testing.expectEqual(@intFromPtr(&win32.LoadLibraryExW), @intFromPtr(platform_operations.load_library_ex_w));
    try std.testing.expectEqual(@intFromPtr(&win32.GetProcAddress), @intFromPtr(platform_operations.get_proc_address));
    try std.testing.expectEqual(@intFromPtr(&win32.FreeLibrary), @intFromPtr(platform_operations.free_library));
}

test "a poisoned NVIDIA backend fails ticks without sampling" {
    const previous_fault = nvml_fault;
    defer nvml_fault = previous_fault;
    nvml_fault = .{ .operation = .graphics_clock, .exception_code = access_violation };

    var instance = Instance{ .host = undefined };
    try std.testing.expectEqual(abi.status_fail, tick(&instance, 0));
}

test "the NVML loader always requests the System32 driver library" {
    const environment = TestEnvironment.init();
    defer environment.deinit();

    test_platform_recorder = .{};
    try std.testing.expectEqual(@as(?win32.HMODULE, null), loadNvml());
    try std.testing.expectEqual(@as(usize, 1), test_platform_recorder.load_calls);
    try std.testing.expectEqualSlices(u16, win32.L("nvml.dll")[0.."nvml.dll".len], test_platform_recorder.name[0..test_platform_recorder.name_length]);
    try std.testing.expectEqual(@as(?win32.HANDLE, null), test_platform_recorder.file);
    try std.testing.expectEqual(win32.LOAD_LIBRARY_SEARCH_SYSTEM32, test_platform_recorder.flags);
}

test "a missing NVML module performs no initialization or cleanup" {
    const environment = TestEnvironment.init();
    defer environment.deinit();

    test_platform_recorder.load_result = null;
    var host_state = TestHostState{};
    var host = host_state.host();
    var instance: ?*anyopaque = null;
    try std.testing.expectEqual(abi.status_ok, open(&host, null, &instance));
    defer if (instance) |pointer| close(pointer, 0);

    try std.testing.expectEqual(@as(usize, 1), test_platform_recorder.load_calls);
    try std.testing.expectEqual(@as(usize, 0), test_platform_recorder.get_proc_address_calls);
    try std.testing.expectEqual(@as(usize, 0), test_nvml_state.initialize_calls);
    try std.testing.expectEqual(@as(usize, 0), test_nvml_state.shutdown_calls);
    try std.testing.expectEqual(@as(usize, 0), test_platform_recorder.free_calls);
}

test "a poisoned NVIDIA backend rejects reopen before loading or allocating" {
    const environment = TestEnvironment.init();
    defer environment.deinit();

    test_platform_recorder = .{};
    nvml_fault = .{ .operation = .graphics_clock, .exception_code = access_violation };
    var host_state = TestHostState{};
    var host = host_state.host();
    var instance: ?*anyopaque = @ptrFromInt(1);
    const status = open(&host, null, &instance);
    defer if (instance) |pointer| close(pointer, 0);

    try std.testing.expectEqual(abi.status_fail, status);
    try std.testing.expectEqual(@as(?*anyopaque, null), instance);
    try std.testing.expectEqual(@as(usize, 0), test_platform_recorder.load_calls);
}

test "an NVML access violation stops sampling and disables the backend until restart" {
    const environment = TestEnvironment.init();
    defer environment.deinit();

    var host_state = TestHostState{};
    var host = host_state.host();
    var instance: ?*anyopaque = null;
    try std.testing.expectEqual(abi.status_ok, open(&host, null, &instance));
    defer if (instance) |pointer| close(pointer, 0);

    test_guard_script = .{ .fault_on_call = 5 };
    try std.testing.expectEqual(abi.status_fail, tick(instance, 0));
    try std.testing.expectEqual(@as(?NvmlFault, .{ .operation = .graphics_clock, .exception_code = access_violation }), nvml_fault);
    try std.testing.expectEqual(@as(usize, 1), test_nvml_state.temperature_calls);
    try std.testing.expectEqual(@as(usize, 1), test_nvml_state.utilization_calls);
    try std.testing.expectEqual(@as(usize, 1), test_nvml_state.power_calls);
    try std.testing.expectEqual(@as(usize, 1), test_nvml_state.fan_rpm_calls);
    try std.testing.expectEqual(@as(usize, 0), test_nvml_state.clock_calls);
    try std.testing.expectEqual(@as(usize, 0), test_nvml_state.memory_calls);
    try std.testing.expect(host_state.published_sensors[@intFromEnum(Sensor.temp)]);
    try std.testing.expect(host_state.published_sensors[@intFromEnum(Sensor.load)]);
    try std.testing.expect(host_state.published_sensors[@intFromEnum(Sensor.power)]);
    try std.testing.expect(host_state.published_sensors[@intFromEnum(Sensor.fan)]);
    try std.testing.expect(!host_state.published_sensors[@intFromEnum(Sensor.freq)]);
    try std.testing.expect(!host_state.published_sensors[@intFromEnum(Sensor.mem_freq)]);
    try std.testing.expect(!host_state.published_sensors[@intFromEnum(Sensor.mem_load)]);
    try std.testing.expectEqual(@as(usize, 1), host_state.fault_log_count);
    try std.testing.expectEqualStrings(
        "NVML access violation in nvmlDeviceGetClockInfo(graphics) (0xC0000005); NVIDIA GPU sensors are disabled until rgbctrl restarts.",
        host_state.last_fault_log[0..host_state.last_fault_log_length],
    );

    const invocation_count = test_guard_script.invocation_count;
    const sensor_set_count = host_state.sensor_set_count;
    try std.testing.expectEqual(abi.status_fail, tick(instance, 1000));
    try std.testing.expectEqual(invocation_count, test_guard_script.invocation_count);
    try std.testing.expectEqual(sensor_set_count, host_state.sensor_set_count);
    try std.testing.expectEqual(@as(usize, 1), host_state.fault_log_count);

    const pointer = instance.?;
    instance = null;
    close(pointer, 0);
    try std.testing.expectEqual(@as(usize, 0), test_nvml_state.shutdown_calls);
    try std.testing.expectEqual(@as(usize, 0), test_platform_recorder.free_calls);

    var reopened: ?*anyopaque = @ptrFromInt(1);
    try std.testing.expectEqual(abi.status_fail, open(&host, null, &reopened));
    try std.testing.expectEqual(@as(?*anyopaque, null), reopened);
    try std.testing.expectEqual(@as(usize, 1), test_platform_recorder.load_calls);
    try std.testing.expectEqual(@as(usize, 1), host_state.fault_log_count);
}

test "an initialization access violation fails open without shutdown or unload" {
    const environment = TestEnvironment.init();
    defer environment.deinit();

    test_guard_script.fault_on_call = 1;
    var host_state = TestHostState{};
    var host = host_state.host();
    var instance: ?*anyopaque = @ptrFromInt(1);
    try std.testing.expectEqual(abi.status_fail, open(&host, null, &instance));
    try std.testing.expectEqual(@as(?*anyopaque, null), instance);
    try std.testing.expectEqual(@as(usize, 0), live_instances);
    try std.testing.expectEqual(@as(usize, 0), test_nvml_state.initialize_calls);
    try std.testing.expectEqual(@as(usize, 0), test_nvml_state.shutdown_calls);
    try std.testing.expectEqual(@as(usize, 0), test_platform_recorder.free_calls);
    try std.testing.expectEqual(@as(?NvmlFault, .{ .operation = .initialize, .exception_code = access_violation }), nvml_fault);
    try std.testing.expectEqual(@as(usize, 1), host_state.fault_log_count);
}

test "every NVML open call is guarded and poisons at its operation boundary" {
    const cases = [_]struct { fault_call: usize, operation: Operation }{
        .{ .fault_call = 1, .operation = .initialize },
        .{ .fault_call = 2, .operation = .device_handle },
        .{ .fault_call = 3, .operation = .fan_count },
        .{ .fault_call = 4, .operation = .device_name },
    };
    for (cases) |case| try expectOpenFault(case.fault_call, case.operation);
}

test "every NVML sampling call is guarded and poisons at its operation boundary" {
    const cases = [_]struct { fault_call: usize, operation: Operation }{
        .{ .fault_call = 1, .operation = .temperature },
        .{ .fault_call = 2, .operation = .utilization },
        .{ .fault_call = 3, .operation = .power },
        .{ .fault_call = 4, .operation = .fan_rpm },
        .{ .fault_call = 5, .operation = .graphics_clock },
        .{ .fault_call = 6, .operation = .memory_clock },
        .{ .fault_call = 7, .operation = .memory_info },
    };
    for (cases) |case| try expectSampleFault(case.fault_call, case.operation);
}

test "a later fan access violation suppresses the combined fan publication" {
    const environment = TestEnvironment.init();
    defer environment.deinit();

    test_nvml_state.fan_count = 3;
    var host_state = TestHostState{};
    var host = host_state.host();
    var instance: ?*anyopaque = null;
    try std.testing.expectEqual(abi.status_ok, open(&host, null, &instance));
    defer if (instance) |pointer| close(pointer, 0);

    test_guard_script = .{ .fault_on_call = 5 };
    try std.testing.expectEqual(abi.status_fail, tick(instance, 0));
    try std.testing.expectEqual(@as(usize, 1), test_nvml_state.fan_rpm_calls);
    try std.testing.expect(!host_state.published_sensors[@intFromEnum(Sensor.fan)]);
    try std.testing.expectEqual(@as(?NvmlFault, .{ .operation = .fan_rpm, .exception_code = access_violation }), nvml_fault);
}

test "a missing required NVML symbol unloads without initializing" {
    const environment = TestEnvironment.init();
    defer environment.deinit();

    test_platform_recorder.missing_symbol = "nvmlShutdown";
    var host_state = TestHostState{};
    var host = host_state.host();
    var instance: ?*anyopaque = null;
    try std.testing.expectEqual(abi.status_ok, open(&host, null, &instance));
    defer if (instance) |pointer| close(pointer, 0);

    try std.testing.expectEqual(@as(usize, 0), test_nvml_state.initialize_calls);
    try std.testing.expectEqual(@as(usize, 0), test_nvml_state.shutdown_calls);
    try std.testing.expectEqual(@as(usize, 1), test_platform_recorder.free_calls);
    try std.testing.expectEqual(@as(?NvmlFault, null), nvml_fault);
}

test "an ordinary initialization error unloads without shutdown" {
    const environment = TestEnvironment.init();
    defer environment.deinit();

    test_nvml_state.initialize_status = nvml_error_not_supported;
    var host_state = TestHostState{};
    var host = host_state.host();
    var instance: ?*anyopaque = null;
    try std.testing.expectEqual(abi.status_ok, open(&host, null, &instance));
    defer if (instance) |pointer| close(pointer, 0);

    try std.testing.expectEqual(@as(usize, 1), test_nvml_state.initialize_calls);
    try std.testing.expectEqual(@as(usize, 0), test_nvml_state.shutdown_calls);
    try std.testing.expectEqual(@as(usize, 1), test_platform_recorder.free_calls);
    try std.testing.expectEqual(@as(?NvmlFault, null), nvml_fault);
}

test "an ordinary device-handle error shuts down before unload" {
    const environment = TestEnvironment.init();
    defer environment.deinit();

    test_nvml_state.handle_status = nvml_error_not_supported;
    var host_state = TestHostState{};
    var host = host_state.host();
    var instance: ?*anyopaque = null;
    try std.testing.expectEqual(abi.status_ok, open(&host, null, &instance));
    defer if (instance) |pointer| close(pointer, 0);

    try std.testing.expectEqual(@as(usize, 1), test_nvml_state.initialize_calls);
    try std.testing.expectEqual(@as(usize, 1), test_nvml_state.handle_calls);
    try std.testing.expectEqual(@as(usize, 1), test_nvml_state.shutdown_calls);
    try std.testing.expectEqual(@as(usize, 1), test_platform_recorder.free_calls);
    try std.testing.expectEqual(@as(?NvmlFault, null), nvml_fault);
}

test "a shutdown fault after an ordinary handle error skips unload and fails open" {
    const environment = TestEnvironment.init();
    defer environment.deinit();

    test_nvml_state.handle_status = nvml_error_not_supported;
    test_guard_script.fault_on_call = 3;
    var host_state = TestHostState{};
    var host = host_state.host();
    var instance: ?*anyopaque = @ptrFromInt(1);
    try std.testing.expectEqual(abi.status_fail, open(&host, null, &instance));
    try std.testing.expectEqual(@as(?*anyopaque, null), instance);
    try std.testing.expectEqual(@as(usize, 0), test_nvml_state.shutdown_calls);
    try std.testing.expectEqual(@as(usize, 0), test_platform_recorder.free_calls);
    try std.testing.expectEqual(@as(?NvmlFault, .{ .operation = .shutdown, .exception_code = access_violation }), nvml_fault);
    try std.testing.expectEqual(@as(usize, 0), live_instances);
}

test "ordinary optional discovery errors keep the initialized backend" {
    const environment = TestEnvironment.init();
    defer environment.deinit();

    test_nvml_state.fan_count_status = nvml_error_not_supported;
    test_nvml_state.name_status = nvml_error_not_supported;
    var host_state = TestHostState{};
    var host = host_state.host();
    var instance: ?*anyopaque = null;
    try std.testing.expectEqual(abi.status_ok, open(&host, null, &instance));
    defer if (instance) |pointer| close(pointer, 0);

    try std.testing.expectEqual(@as(usize, 0), test_platform_recorder.free_calls);
    try std.testing.expectEqual(abi.status_ok, tick(instance, 0));
    try std.testing.expectEqual(@as(usize, sensor_names.len), host_state.sensor_set_count);
    try std.testing.expectEqual(@as(?NvmlFault, null), nvml_fault);
}

test "healthy close guards shutdown and then unloads the module" {
    const environment = TestEnvironment.init();
    defer environment.deinit();

    var host_state = TestHostState{};
    var host = host_state.host();
    var instance: ?*anyopaque = null;
    try std.testing.expectEqual(abi.status_ok, open(&host, null, &instance));
    const open_guard_calls = test_guard_script.invocation_count;
    const pointer = instance.?;
    instance = null;
    close(pointer, 0);

    try std.testing.expectEqual(open_guard_calls + 1, test_guard_script.invocation_count);
    try std.testing.expectEqual(@as(usize, 1), test_nvml_state.shutdown_calls);
    try std.testing.expectEqual(@as(usize, 1), test_platform_recorder.free_calls);
    try std.testing.expectEqual(@as(usize, 0), live_instances);
    try std.testing.expectEqual(@as(?NvmlFault, null), nvml_fault);
}

test "a shutdown access violation poisons the backend and skips unload" {
    const environment = TestEnvironment.init();
    defer environment.deinit();

    var host_state = TestHostState{};
    var host = host_state.host();
    var instance: ?*anyopaque = null;
    try std.testing.expectEqual(abi.status_ok, open(&host, null, &instance));
    test_guard_script = .{ .fault_on_call = 1 };
    const pointer = instance.?;
    instance = null;
    close(pointer, 0);

    try std.testing.expectEqual(@as(usize, 0), test_nvml_state.shutdown_calls);
    try std.testing.expectEqual(@as(usize, 0), test_platform_recorder.free_calls);
    try std.testing.expectEqual(@as(?NvmlFault, .{ .operation = .shutdown, .exception_code = access_violation }), nvml_fault);
    try std.testing.expectEqual(@as(usize, 1), host_state.fault_log_count);
    try std.testing.expectEqual(@as(usize, 0), live_instances);
}

test "test cleanup restores every mutable NVIDIA seam and panic route" {
    const original_fault = nvml_fault;
    const original_panic_host = panic_host;
    const original_panic_hook = sdk.panic.hook;
    const original_live_instances = live_instances;
    const original_guarded_invoker = guarded_invoker;
    const original_platform_operations = platform_operations;
    const original_platform_recorder = test_platform_recorder;
    const original_nvml_state = test_nvml_state;
    const original_guard_script = test_guard_script;
    defer {
        nvml_fault = original_fault;
        panic_host = original_panic_host;
        sdk.panic.hook = original_panic_hook;
        live_instances = original_live_instances;
        guarded_invoker = original_guarded_invoker;
        platform_operations = original_platform_operations;
        test_platform_recorder = original_platform_recorder;
        test_nvml_state = original_nvml_state;
        test_guard_script = original_guard_script;
    }

    var host_state = TestHostState{};
    var host = host_state.host();
    nvml_fault = .{ .operation = .memory_info, .exception_code = access_violation };
    panic_host = &host;
    sdk.panic.hook = testPanicHook;
    test_platform_recorder = .{ .load_calls = 7 };
    test_nvml_state = .{ .clock_calls = 8 };
    test_guard_script = .{ .invocation_count = 9 };
    const environment = TestEnvironment.init();

    nvml_fault = .{ .operation = .shutdown, .exception_code = 1 };
    panic_host = null;
    sdk.panic.hook = null;
    test_platform_recorder.load_calls = 70;
    test_nvml_state.clock_calls = 80;
    test_guard_script.invocation_count = 90;
    environment.deinit();

    try std.testing.expectEqual(@as(?NvmlFault, .{ .operation = .memory_info, .exception_code = access_violation }), nvml_fault);
    try std.testing.expectEqual(@intFromPtr(&host), @intFromPtr(panic_host.?));
    try std.testing.expectEqual(@intFromPtr(&testPanicHook), @intFromPtr(sdk.panic.hook.?));
    try std.testing.expectEqual(@intFromPtr(original_guarded_invoker), @intFromPtr(guarded_invoker));
    try std.testing.expectEqual(@intFromPtr(original_platform_operations.load_library_ex_w), @intFromPtr(platform_operations.load_library_ex_w));
    try std.testing.expectEqual(@intFromPtr(original_platform_operations.get_proc_address), @intFromPtr(platform_operations.get_proc_address));
    try std.testing.expectEqual(@intFromPtr(original_platform_operations.free_library), @intFromPtr(platform_operations.free_library));
    try std.testing.expectEqual(@as(usize, 7), test_platform_recorder.load_calls);
    try std.testing.expectEqual(@as(usize, 8), test_nvml_state.clock_calls);
    try std.testing.expectEqual(@as(usize, 9), test_guard_script.invocation_count);
}
