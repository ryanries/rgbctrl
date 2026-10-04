const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("sdk");
const protocol = @import("protocol.zig");
const abi = sdk.abi;

comptime {
    if (!builtin.is_test) _ = @import("rt");
}

pub const panic = sdk.panic;

const device_id = "ram";
const device_name = "Corsair Vengeance RGB DDR5";
const frame_interval_ms: u64 = 34;
const mutex_timeout_ms: u32 = 10;
const debug_log_interval_ms: u64 = 60000;
const smbus_xfer = "ioctl_smbus_xfer";
const piix4_port_select = "ioctl_piix4_port_sel";
const set_sleep_mode = "ioctl_set_sleep_mode";

const zone_names = [_][*:0]const u8{ "dimm1", "dimm2", "dimm3", "dimm4", "dimm5", "dimm6", "dimm7", "dimm8" };

const AddressSlot = struct {
    state: protocol.GuardState = .unknown,
    colors: [protocol.led_count]abi.Rgb = @splat(abi.Rgb.black),
    last_sent: [protocol.led_count]abi.Rgb = @splat(abi.Rgb.black),
    dirty: bool = false,
};

const Instance = struct {
    host: sdk.HostApi,
    module: ?sdk.pawnio.Module = null,
    smbus_mutex: sdk.pawnio.InteropMutex = .{ .handle = null },
    addresses: [protocol.address_count]AddressSlot = @splat(.{}),
    zone_infos: [protocol.address_count]abi.ZoneInfo = undefined,
    zone_pointers: [protocol.address_count]*const abi.ZoneInfo = undefined,
    zone_address_indices: [protocol.address_count]usize = undefined,
    device_info: abi.DeviceInfo = .{ .zone_count = 0, .id = device_id, .name = device_name, .zones = null, .max_fps = 30 },
    port_to_restore: ?u64 = null,
    last_frame_ms: u64 = 0,
    next_mutex_debug_ms: u64 = 0,

    fn openModule(self: *Instance) void {
        var status: sdk.win32.NTSTATUS = 0;
        self.module = sdk.pawnio.Module.open(std.heap.page_allocator, self.host.hostDir(), sdk.pawnio.smbus_piix4, &status) catch |err| {
            self.host.err("corsair_ddr5 unavailable: {s}", .{sdk.pawnio.describeOpenError(err)});
            return;
        };
        self.smbus_mutex = sdk.pawnio.InteropMutex.open(sdk.pawnio.smbus_mutex_name);
        if (!self.smbus_mutex.isUsable()) {
            self.host.err("the shared SMBus mutex Global\\Access_SMBUS.HTP.Method cannot be opened (Win32 error {d}); DDR5 lighting stays off because the bus cannot be shared safely", .{sdk.win32.GetLastError()});
            return;
        }
        self.trySetSleepMode();
    }

    fn closeModule(self: *Instance) void {
        self.restoreSelectedPort();
        self.smbus_mutex.close();
        if (self.module) |*module| module.close();
        self.module = null;
    }

    fn trySetSleepMode(self: *Instance) void {
        var module = &(self.module orelse return);
        var input = [_]u64{2};
        var output: [0]u64 = .{};
        module.execute(set_sleep_mode, &input, &output) catch {
            self.host.debug("SmbusPIIX4 sleep mode 2 is unavailable", .{});
        };
    }

    fn selectPortZero(self: *Instance) bool {
        var module = &(self.module orelse return false);
        var input = [_]u64{0};
        var output: [1]u64 = undefined;
        module.execute(piix4_port_select, &input, &output) catch {
            self.host.debug("SmbusPIIX4 port select failed with NTSTATUS 0x{x:0>8}", .{@as(u32, @bitCast(module.last_status))});
            return false;
        };
        self.port_to_restore = output[0];
        return true;
    }

    fn restoreSelectedPort(self: *Instance) void {
        const previous = self.port_to_restore orelse return;
        self.port_to_restore = null;
        var module = &(self.module orelse return);
        var input = [_]u64{previous};
        var output: [1]u64 = undefined;
        module.execute(piix4_port_select, &input, &output) catch {
            self.host.debug("SmbusPIIX4 port restore failed with NTSTATUS 0x{x:0>8}", .{@as(u32, @bitCast(module.last_status))});
        };
    }

    fn acquireSmbus(self: *Instance, action: []const u8) bool {
        if (self.smbus_mutex.acquire(mutex_timeout_ms)) return true;
        const now_ms = self.host.nowMs();
        if (now_ms >= self.next_mutex_debug_ms) {
            self.host.debug("skipping {s}; SMBus mutex was busy", .{action});
            self.next_mutex_debug_ms = now_ms + debug_log_interval_ms;
        }
        return false;
    }

    fn readByte(self: *Instance, address: u8, command: u8) !u8 {
        if (!protocol.isAllowedAddress(address)) return error.BadAddress;
        var module = &(self.module orelse return error.NoModule);
        var input = [_]u64{ address, 1, command, 2, 0 };
        var output: [1]u64 = undefined;
        try module.execute(smbus_xfer, &input, &output);
        return @intCast(output[0] & 0xFF);
    }

    fn writeByte(self: *Instance, address: u8, command: u8, value: u8) !void {
        if (!protocol.isAllowedAddress(address)) return error.BadAddress;
        var module = &(self.module orelse return error.NoModule);
        var input = [_]u64{ address, 0, command, 2, value };
        var output: [0]u64 = .{};
        try module.execute(smbus_xfer, &input, &output);
    }

    fn writeFrame(self: *Instance, address: u8, frame: *const [protocol.frame_length]u8) !void {
        if (!protocol.isAllowedAddress(address)) return error.BadAddress;
        var module = &(self.module orelse return error.NoModule);
        var input: [9]u64 = @splat(0);
        input[0] = address;
        input[1] = 0;
        input[2] = protocol.direct_command;
        input[3] = 5;
        const packed_bytes = std.mem.sliceAsBytes(input[4..9]);
        packed_bytes[0] = protocol.direct_payload_count;
        @memcpy(packed_bytes[1 .. 1 + protocol.frame_length], frame);
        var output: [0]u64 = .{};
        try module.execute(smbus_xfer, &input, &output);
    }

    fn markObservation(self: *Instance, address_index: usize, observation: protocol.Observation) void {
        self.addresses[address_index].state = protocol.applyObservation(self.addresses[address_index].state, observation).state;
    }

    fn probeAddress(self: *Instance, address_index: usize) void {
        if (self.addresses[address_index].state != .unknown) return;
        if (!self.acquireSmbus("DDR5 probe")) return;
        defer self.smbus_mutex.release();
        const address = protocol.addressAt(address_index);
        if (!self.selectPortZero()) {
            self.markObservation(address_index, .transaction_failed);
            return;
        }
        defer self.restoreSelectedPort();
        const register_43 = self.readByte(address, 0x43) catch {
            self.markObservation(address_index, .transaction_failed);
            return;
        };
        const register_44 = self.readByte(address, 0x44) catch {
            self.markObservation(address_index, .transaction_failed);
            return;
        };
        self.markObservation(address_index, .{ .stage1 = .{ .register_43 = register_43, .register_44 = register_44 } });
        if (self.addresses[address_index].state != .stage1) return;
        self.writeByte(address, 0x61, 0) catch {
            self.markObservation(address_index, .transaction_failed);
            return;
        };
        self.writeByte(address, 0x21, 0) catch {
            self.markObservation(address_index, .transaction_failed);
            return;
        };
        var block: [protocol.info_length]u8 = undefined;
        for (&block) |*byte| {
            byte.* = self.readByte(address, 0x40) catch {
                self.markObservation(address_index, .transaction_failed);
                return;
            };
        }
        const info_crc = self.readByte(address, 0x42) catch {
            self.markObservation(address_index, .transaction_failed);
            return;
        };
        self.markObservation(address_index, .{ .info = .{ .block = block, .crc = info_crc } });
        if (self.addresses[address_index].state == .verified) {
            if (protocol.parseInfo(block, info_crc)) |info| {
                self.host.debug("verified Corsair DDR5 RGB at SMBus 0x{x:0>2}, product 0x{x:0>4}, protocol {d}", .{ address, info.product_id, info.protocol_version });
            }
        }
    }

    fn resetProbeableAddresses(self: *Instance) void {
        for (&self.addresses) |*slot| {
            slot.state = protocol.applyObservation(slot.state, .recover).state;
        }
    }

    fn scanUnknownAddresses(self: *Instance) void {
        for (0..protocol.address_count) |address_index| self.probeAddress(address_index);
        self.rebuildDeviceInfo();
    }

    fn rebuildDeviceInfo(self: *Instance) void {
        var zone_index: usize = 0;
        for (&self.addresses, 0..) |*slot, address_index| {
            if (slot.state != .verified) continue;
            self.zone_address_indices[zone_index] = address_index;
            self.zone_infos[zone_index] = .{
                .flags = abi.zone_host_frames,
                .name = zone_names[zone_index],
                .led_count = protocol.led_count,
                .max_leds = protocol.led_count,
                .hw_effects = 0,
                .hw_max_colors = 0,
                .led_x = null,
            };
            self.zone_pointers[zone_index] = &self.zone_infos[zone_index];
            zone_index += 1;
        }
        self.device_info = .{
            .zone_count = @intCast(zone_index),
            .id = device_id,
            .name = device_name,
            .zones = if (zone_index == 0) null else self.zone_pointers[0..zone_index].ptr,
            .max_fps = 30,
        };
    }

    fn verifiedCount(self: *const Instance) u32 {
        var count: u32 = 0;
        for (&self.addresses) |*slot| {
            if (slot.state == .verified) count += 1;
        }
        return count;
    }

    fn verifiedMask(self: *const Instance) u8 {
        var mask: u8 = 0;
        for (&self.addresses, 0..) |*slot, address_index| {
            if (slot.state == .verified) mask |= @as(u8, 1) << @as(u3, @intCast(address_index));
        }
        return mask;
    }

    fn hasDirtyFrame(self: *const Instance) bool {
        for (0..self.device_info.zone_count) |zone_index| {
            const address_index = self.zone_address_indices[zone_index];
            if (self.addresses[address_index].dirty) return true;
        }
        return false;
    }

    fn markVerifiedDirty(self: *Instance) void {
        for (&self.addresses) |*slot| {
            if (slot.state == .verified) slot.dirty = true;
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
    self.openModule();
    if (self.module != null) self.scanUnknownAddresses();
    instance_out.* = self;
    return abi.status_ok;
}

fn close(pointer: ?*anyopaque, reason: u32) callconv(.c) void {
    _ = reason;
    const self = instanceFrom(pointer);
    self.closeModule();
    std.heap.page_allocator.destroy(self);
}

fn deviceCount(pointer: ?*anyopaque) callconv(.c) u32 {
    return if (instanceFrom(pointer).verifiedCount() == 0) 0 else 1;
}

fn deviceInfo(pointer: ?*anyopaque, device_index: u32) callconv(.c) ?*const abi.DeviceInfo {
    const self = instanceFrom(pointer);
    if (device_index != 0 or self.verifiedCount() == 0) return null;
    return &self.device_info;
}

fn setLeds(pointer: ?*anyopaque, device_index: u32, zone_index: u32, colors: [*]const abi.Rgb, count: u32) callconv(.c) i32 {
    const self = instanceFrom(pointer);
    if (device_index != 0 or zone_index >= self.device_info.zone_count or count != protocol.led_count) return abi.status_argument;
    const address_index = self.zone_address_indices[zone_index];
    var changed = false;
    for (&self.addresses[address_index].colors, 0..) |*target, index| {
        const color = colors[index];
        if (!abi.Rgb.eql(target.*, color)) {
            target.* = color;
            changed = true;
        }
    }
    if (changed) self.addresses[address_index].dirty = true;
    return abi.status_ok;
}

fn flush(pointer: ?*anyopaque, device_index: u32) callconv(.c) i32 {
    const self = instanceFrom(pointer);
    if (device_index != 0) return abi.status_argument;
    if (!self.hasDirtyFrame()) return abi.status_ok;
    const now_ms = self.host.nowMs();
    if (self.last_frame_ms != 0 and now_ms -| self.last_frame_ms < frame_interval_ms) return abi.status_ok;
    if (!self.acquireSmbus("DDR5 frame")) return abi.status_ok;
    defer self.smbus_mutex.release();
    if (!self.selectPortZero()) return abi.status_device_lost;
    defer self.restoreSelectedPort();
    for (0..self.device_info.zone_count) |zone_index| {
        const address_index = self.zone_address_indices[zone_index];
        var slot = &self.addresses[address_index];
        if (!slot.dirty or slot.state != .verified) continue;
        const frame = protocol.buildFrame(&slot.colors);
        self.writeFrame(protocol.addressAt(address_index), &frame) catch {
            slot.state = protocol.applyObservation(slot.state, .frame_write_failed).state;
            slot.dirty = true;
            self.rebuildDeviceInfo();
            return abi.status_device_lost;
        };
        slot.last_sent = slot.colors;
        slot.dirty = false;
    }
    self.last_frame_ms = now_ms;
    return abi.status_ok;
}

fn rescan(pointer: ?*anyopaque, reason: u32) callconv(.c) i32 {
    const self = instanceFrom(pointer);
    if (reason == abi.rescan_hotplug) return abi.status_ok;
    if (self.module == null) return abi.status_ok;
    const previous_mask = self.verifiedMask();
    if (reason == abi.rescan_resume) self.markVerifiedDirty();
    if (reason == abi.rescan_resume or reason == abi.rescan_recover) {
        self.resetProbeableAddresses();
        self.scanUnknownAddresses();
    }
    return if (self.verifiedMask() != previous_mask) abi.rescan_changed else abi.status_ok;
}

const plugin = abi.Plugin{
    .name = "corsair_ddr5",
    .version = "0.1.0",
    .flags = abi.plugin_opt_in,
    .transports = abi.transport_smbus,
    .open = open,
    .close = close,
    .device_count = deviceCount,
    .device_info = deviceInfo,
    .set_leds = setLeds,
    .flush = flush,
    .rescan = rescan,
};

export fn rgbctrl_plugin_entry(host_abi_version: u32) callconv(.c) ?*const abi.Plugin {
    if (host_abi_version < 1) return null;
    return &plugin;
}

test {
    _ = protocol;
}
