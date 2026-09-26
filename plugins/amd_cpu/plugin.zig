const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("sdk");
const protocol = @import("protocol.zig");
const abi = sdk.abi;

comptime {
    if (!builtin.is_test) _ = @import("rt");
}

pub const panic = sdk.panic;

const mutex_timeout_ms: u32 = 10;
const read_debug_interval_ms: u64 = 10000;
const ccd_sensor_names = [_][]const u8{
    "cpu.ccd0.temp",
    "cpu.ccd1.temp",
    "cpu.ccd2.temp",
    "cpu.ccd3.temp",
    "cpu.ccd4.temp",
    "cpu.ccd5.temp",
    "cpu.ccd6.temp",
    "cpu.ccd7.temp",
};

const CpuidResult = struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
};

const ProcessorSupport = struct {
    supported: bool,
    family: u32,
};

const RateLimit = struct {
    last_ms: ?u64 = null,

    fn shouldLog(self: *RateLimit, now_ms: u64) bool {
        if (self.last_ms) |last_ms| {
            if (now_ms -| last_ms < read_debug_interval_ms) return false;
        }
        self.last_ms = now_ms;
        return true;
    }
};

const Instance = struct {
    host: sdk.HostApi,
    module: ?sdk.pawnio.Module = null,
    pci_mutex: ?sdk.pawnio.InteropMutex = null,
    qpc_frequency: i64 = 0,
    energy_unit_joules: ?f64 = null,
    previous_energy_counter: ?u32 = null,
    previous_energy_ticks: ?i64 = null,
    smn_read_limit: RateLimit = .{},
    msr_read_limit: RateLimit = .{},

    fn closeModule(self: *Instance) void {
        if (self.module) |*module| module.close();
        self.module = null;
        if (self.pci_mutex) |*mutex| mutex.close();
        self.pci_mutex = null;
    }

    fn readSmn(self: *Instance, address: u32, now_ms: u64) ?u32 {
        var module = &(self.module orelse return null);
        const input = [_]u64{address};
        var output: [1]u64 = undefined;
        module.execute("ioctl_read_smn", &input, &output) catch |err| {
            if (self.smn_read_limit.shouldLog(now_ms)) self.host.debug("PawnIO SMN read failed at 0x{x}: {s} NTSTATUS 0x{x:0>8}", .{ address, @errorName(err), @as(u32, @bitCast(module.last_status)) });
            return null;
        };
        return @intCast(output[0] & 0xFFFFFFFF);
    }

    fn readMsr(self: *Instance, msr: u64, now_ms: u64) ?u64 {
        var module = &(self.module orelse return null);
        const input = [_]u64{msr};
        var output: [1]u64 = undefined;
        module.execute("ioctl_read_msr", &input, &output) catch |err| {
            if (self.msr_read_limit.shouldLog(now_ms)) self.host.debug("PawnIO MSR read failed at 0x{x}: {s} NTSTATUS 0x{x:0>8}", .{ msr, @errorName(err), @as(u32, @bitCast(module.last_status)) });
            return null;
        };
        return output[0];
    }

    fn publishTemperatures(self: *Instance, now_ms: u64) bool {
        const mutex = self.pci_mutex orelse return false;
        if (!mutex.acquire(mutex_timeout_ms)) return false;
        defer mutex.release();
        if (self.readSmn(protocol.control_temperature_register, now_ms)) |raw| {
            if (protocol.normalizeTemperature(protocol.decodeControlTemperature(raw))) |temperature| self.host.setSensor("cpu.temp", temperature);
        }
        for (0..protocol.ccd_temperature_count) |index| {
            const address: u32 = protocol.ccd_temperature_base_register + @as(u32, @intCast(index * 4));
            if (self.readSmn(address, now_ms)) |raw| {
                if (protocol.decodeCcdTemperature(raw)) |temperature| {
                    if (protocol.normalizeTemperature(temperature)) |normalized| self.host.setSensor(ccd_sensor_names[index], normalized);
                }
            }
        }
        return true;
    }

    fn publishPower(self: *Instance, now_ms: u64) void {
        const unit = self.energy_unit_joules orelse blk: {
            const unit_msr = self.readMsr(protocol.rapl_unit_msr, now_ms) orelse return;
            const computed = protocol.energyUnitJoules(unit_msr);
            self.energy_unit_joules = computed;
            break :blk computed;
        };
        const energy_msr = self.readMsr(protocol.rapl_energy_status_msr, now_ms) orelse return;
        var ticks: i64 = 0;
        if (sdk.win32.QueryPerformanceCounter(&ticks) == 0) return;
        const computation = protocol.computePower(self.previous_energy_counter, self.previous_energy_ticks, @intCast(energy_msr & 0xFFFFFFFF), ticks, self.qpc_frequency, unit);
        self.previous_energy_counter = computation.next_counter;
        self.previous_energy_ticks = computation.next_ticks;
        if (computation.power_watts) |power_watts| {
            if (protocol.normalizePower(power_watts)) |normalized| self.host.setSensor("cpu.power", normalized);
        }
    }
};

var panic_host: ?*const abi.Host = null;

fn reportPanic(message: []const u8) void {
    const host = panic_host orelse return;
    host.log(host.ctx, @intFromEnum(abi.LogLevel.err), message.ptr, message.len);
}

fn cpuid(leaf: u32, subleaf: u32) CpuidResult {
    var eax: u32 = leaf;
    var ebx: u32 = 0;
    var ecx: u32 = subleaf;
    var edx: u32 = 0;
    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (eax),
          [subleaf] "{ecx}" (ecx),
    );
    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

fn processorSupport() ProcessorSupport {
    if (builtin.cpu.arch != .x86_64) return .{ .supported = false, .family = 0 };
    const vendor = cpuid(0, 0);
    var vendor_bytes: [12]u8 = undefined;
    std.mem.writeInt(u32, vendor_bytes[0..4], vendor.ebx, .little);
    std.mem.writeInt(u32, vendor_bytes[4..8], vendor.edx, .little);
    std.mem.writeInt(u32, vendor_bytes[8..12], vendor.ecx, .little);
    if (!std.mem.eql(u8, &vendor_bytes, "AuthenticAMD")) return .{ .supported = false, .family = 0 };
    const version = cpuid(1, 0);
    const base_family = (version.eax >> 8) & 0xF;
    const extended_family = (version.eax >> 20) & 0xFF;
    const family = base_family + if (base_family == 0xF) extended_family else 0;
    return .{ .supported = family >= 0x17, .family = family };
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
    instance_out.* = self;
    const support = processorSupport();
    if (!support.supported) {
        self.host.info("amd_cpu unsupported CPU vendor or family 0x{x}", .{support.family});
        return abi.status_ok;
    }
    _ = sdk.win32.QueryPerformanceFrequency(&self.qpc_frequency);
    var status: sdk.win32.NTSTATUS = 0;
    self.module = sdk.pawnio.Module.open(std.heap.page_allocator, self.host.hostDir(), sdk.pawnio.amd_family17, &status) catch |err| {
        const description = sdk.pawnio.describeOpenError(err);
        if (err == error.LoadFailed) {
            self.host.err("{s}: NTSTATUS 0x{x:0>8}", .{ description, @as(u32, @bitCast(status)) });
        } else {
            self.host.err("{s}", .{description});
        }
        return abi.status_ok;
    };
    self.pci_mutex = sdk.pawnio.InteropMutex.open(sdk.pawnio.pci_mutex_name);
    if (!self.pci_mutex.?.isUsable()) {
        self.host.err("the shared PCI mutex Global\\Access_PCI cannot be opened (Win32 error {d}); CPU sensors stay off because PCI configuration access cannot be shared safely", .{sdk.win32.GetLastError()});
    }
    return abi.status_ok;
}

fn close(pointer: ?*anyopaque, reason: u32) callconv(.c) void {
    _ = reason;
    const self = instanceFrom(pointer);
    self.closeModule();
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
    const self = instanceFrom(pointer);
    if (self.module == null) return abi.status_ok;
    if (!self.publishTemperatures(now_ms)) return abi.status_ok;
    self.publishPower(now_ms);
    return abi.status_ok;
}

const plugin = abi.Plugin{
    .name = "amd_cpu",
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

test {
    _ = protocol;
}
