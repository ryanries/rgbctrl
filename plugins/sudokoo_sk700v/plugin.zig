const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("sdk");
const protocol = @import("protocol.zig");
const abi = sdk.abi;

comptime {
    if (!builtin.is_test) _ = @import("rt");
}

pub const panic = sdk.panic;

const stale_after_ms: u64 = 5000;
const hold_ms: u64 = 10000;
const write_timeout_ms: u32 = 250;
const device_id = "cooler_display";
const sensor_name_capacity = 31;

const SensorKind = enum { temperature, power, load, frequency };

const sensor_keys = [_][]const u8{ "temp_sensor", "power_sensor", "load_sensor", "freq_sensor" };
const sensor_defaults = [_][]const u8{ "cpu.temp", "cpu.power", "cpu.load", "cpu.freq" };

const SensorSlot = struct {
    name_buffer: [sensor_name_capacity]u8 = undefined,
    name_len: usize = 0,
    last_value: f64 = 0,
    last_good_ms: ?u64 = null,
    warned: bool = false,

    fn name(self: *const SensorSlot) []const u8 {
        return self.name_buffer[0..self.name_len];
    }
};

const Resolution = struct {
    value: f64,
    became_unavailable: bool,
};

fn resolveSensor(slot: *SensorSlot, reading: ?sdk.Sensor, now_ms: u64) Resolution {
    if (reading) |sensor| {
        if (sensor.age_ms <= stale_after_ms) {
            slot.last_value = sensor.value;
            slot.last_good_ms = now_ms -| sensor.age_ms;
            slot.warned = false;
            return .{ .value = sensor.value, .became_unavailable = false };
        }
    }
    if (slot.last_good_ms) |last| {
        if (now_ms -| last <= hold_ms) return .{ .value = slot.last_value, .became_unavailable = false };
    }
    const first = !slot.warned;
    slot.warned = true;
    return .{ .value = 0, .became_unavailable = first };
}

const Instance = struct {
    host: sdk.HostApi,
    device: ?sdk.hid.Device = null,
    present: bool = false,
    path_buffer: [512]u16 = undefined,
    path_len: usize = 0,
    unit: protocol.Unit = .celsius,
    power_bar_max_watts: u16 = protocol.default_power_bar_max_watts,
    blank_on_exit: bool = true,
    exclusive: bool = true,
    sensors: [sensor_keys.len]SensorSlot = [_]SensorSlot{.{}} ** sensor_keys.len,
    open_frame_pending: bool = true,
    device_info: abi.DeviceInfo = .{ .zone_count = 0, .id = device_id, .name = "Sudokoo SK700V display", .zones = null },

    fn path(self: *Instance) [*:0]const u16 {
        return self.path_buffer[0..self.path_len :0];
    }

    fn findDevice(self: *Instance) bool {
        var list = sdk.hid.InterfaceList.init(std.heap.page_allocator) catch {
            self.host.warn("could not enumerate HID interfaces", .{});
            return false;
        };
        defer list.deinit();
        var iterator = list.iterator();
        while (iterator.next()) |candidate| {
            if (!sdk.hid.pathContainsIds(candidate, protocol.vendor_id, protocol.product_id)) continue;
            const info = sdk.hid.queryInfo(candidate.ptr) orelse continue;
            if (info.vendor_id != protocol.vendor_id or info.product_id != protocol.product_id) continue;
            if (info.output_length != protocol.report_length) continue;
            if (candidate.len + 1 > self.path_buffer.len) continue;
            @memcpy(self.path_buffer[0..candidate.len], candidate);
            self.path_buffer[candidate.len] = 0;
            self.path_len = candidate.len;
            var utf8: [512]u8 = undefined;
            self.host.debug("found SK700V at {s} (version 0x{x:0>4})", .{ sdk.text.utf16ToUtf8(&utf8, candidate), info.version });
            return true;
        }
        return false;
    }

    fn openHandle(self: *Instance) bool {
        if (self.device != null) return true;
        const device = sdk.hid.Device.open(self.path(), self.exclusive) catch |err| {
            switch (err) {
                error.SharingViolation => self.host.warn("SK700V is in use by another application (close MasterCraft); retrying later", .{}),
                else => self.host.warn("could not open SK700V: {s}", .{@errorName(err)}),
            }
            return false;
        };
        self.device = device;
        self.open_frame_pending = true;
        return true;
    }

    fn closeHandle(self: *Instance) void {
        if (self.device) |*device| device.close();
        self.device = null;
    }

    fn readConfig(self: *Instance, config: ?*const abi.Json) void {
        for (&self.sensors, 0..) |*slot, index| {
            if (self.host.configString(config, sensor_keys[index], &slot.name_buffer)) |name| {
                slot.name_len = name.len;
            } else {
                const default = sensor_defaults[index];
                @memcpy(slot.name_buffer[0..default.len], default);
                slot.name_len = default.len;
            }
        }
        var unit_buffer: [8]u8 = undefined;
        if (self.host.configString(config, "temperature_unit", &unit_buffer)) |unit| {
            if (std.ascii.eqlIgnoreCase(unit, "F")) {
                self.unit = .fahrenheit;
            } else if (!std.ascii.eqlIgnoreCase(unit, "C")) {
                self.host.warn("temperature_unit must be \"C\" or \"F\"; using C", .{});
            }
        }
        self.power_bar_max_watts = @intCast(self.host.configInt(config, "power_bar_max_watts", protocol.default_power_bar_max_watts, 1, 1000));
        self.blank_on_exit = self.host.configBool(config, "blank_on_exit", true);
        self.exclusive = self.host.configBool(config, "exclusive", true);
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
    panic_host = host;
    sdk.panic.hook = reportPanic;
    const self = std.heap.page_allocator.create(Instance) catch return abi.status_fail;
    self.* = .{ .host = .{ .host = host } };
    self.readConfig(config);
    self.present = self.findDevice();
    if (!self.present) self.host.debug("no SK700V display found", .{});
    instance_out.* = self;
    return abi.status_ok;
}

fn close(pointer: ?*anyopaque, reason: u32) callconv(.c) void {
    const self = instanceFrom(pointer);
    if (reason == abi.close_exit and self.blank_on_exit and self.host.mode() == abi.mode_run) {
        if (self.device) |*device| {
            var frame: [protocol.report_length]u8 = undefined;
            protocol.buildFrame(&frame, .close, protocol.placeholder);
            device.write(&frame, write_timeout_ms) catch {};
        }
    }
    self.closeHandle();
    std.heap.page_allocator.destroy(self);
}

fn deviceCount(pointer: ?*anyopaque) callconv(.c) u32 {
    return if (instanceFrom(pointer).present) 1 else 0;
}

fn deviceInfo(pointer: ?*anyopaque, device_index: u32) callconv(.c) ?*const abi.DeviceInfo {
    const self = instanceFrom(pointer);
    if (!self.present or device_index != 0) return null;
    return &self.device_info;
}

fn tick(pointer: ?*anyopaque, now_ms: u64) callconv(.c) i32 {
    const self = instanceFrom(pointer);
    if (self.host.mode() != abi.mode_run or !self.present) return abi.status_ok;
    if (!self.openHandle()) return abi.status_device_lost;
    var inputs: [sensor_keys.len]f64 = undefined;
    for (&self.sensors, 0..) |*slot, index| {
        const resolution = resolveSensor(slot, self.host.getSensor(slot.name()), now_ms);
        if (resolution.became_unavailable) self.host.warn("sensor {s} unavailable; the display shows 0 for it", .{slot.name()});
        inputs[index] = resolution.value;
    }
    const reading = protocol.toReading(.{
        .temperature_c = inputs[@intFromEnum(SensorKind.temperature)],
        .power_w = inputs[@intFromEnum(SensorKind.power)],
        .load_percent = inputs[@intFromEnum(SensorKind.load)],
        .frequency_mhz = inputs[@intFromEnum(SensorKind.frequency)],
    }, self.unit, self.power_bar_max_watts);
    var frame: [protocol.report_length]u8 = undefined;
    const mode: protocol.Mode = if (self.open_frame_pending) .open else .display;
    protocol.buildFrame(&frame, mode, if (mode == .open) protocol.placeholder else reading);
    var device = &self.device.?;
    device.write(&frame, write_timeout_ms) catch |err| {
        self.host.warn("SK700V write failed: {s} (Win32 error {d})", .{ @errorName(err), device.last_error });
        self.closeHandle();
        return abi.status_device_lost;
    };
    if (mode == .open) {
        self.open_frame_pending = false;
    } else {
        var hex: [64]u8 = undefined;
        self.host.trace("frame {s}", .{sdk.text.hexBytes(&hex, frame[0..20])});
    }
    return abi.status_ok;
}

fn rescan(pointer: ?*anyopaque, reason: u32) callconv(.c) i32 {
    const self = instanceFrom(pointer);
    const was_present = self.present;
    if (reason == abi.rescan_resume) {
        self.closeHandle();
        self.open_frame_pending = true;
        return abi.status_ok;
    }
    if (self.device != null and reason == abi.rescan_hotplug) return abi.status_ok;
    self.closeHandle();
    self.present = self.findDevice();
    if (self.present != was_present) return abi.rescan_changed;
    return abi.status_ok;
}

const plugin = abi.Plugin{
    .name = "sudokoo_sk700v",
    .version = "0.1.0",
    .tick_interval_ms = 1000,
    .transports = abi.transport_hid,
    .open = open,
    .close = close,
    .device_count = deviceCount,
    .device_info = deviceInfo,
    .tick = tick,
    .rescan = rescan,
};

export fn rgbctrl_plugin_entry(host_abi_version: u32) callconv(.c) ?*const abi.Plugin {
    if (host_abi_version < 1) return null;
    return &plugin;
}

test {
    _ = protocol;
}

test "resolveSensor holds the last good value for ten seconds and then reports zero once" {
    var slot = SensorSlot{};
    try std.testing.expectEqual(@as(f64, 55.5), resolveSensor(&slot, .{ .value = 55.5, .age_ms = 100 }, 1000).value);
    const held = resolveSensor(&slot, .{ .value = 99, .age_ms = 6000 }, 5000);
    try std.testing.expectEqual(@as(f64, 55.5), held.value);
    try std.testing.expect(!held.became_unavailable);
    const expired = resolveSensor(&slot, null, 20000);
    try std.testing.expectEqual(@as(f64, 0), expired.value);
    try std.testing.expect(expired.became_unavailable);
    try std.testing.expect(!resolveSensor(&slot, null, 21000).became_unavailable);
    try std.testing.expectEqual(@as(f64, 42), resolveSensor(&slot, .{ .value = 42, .age_ms = 0 }, 22000).value);
}
