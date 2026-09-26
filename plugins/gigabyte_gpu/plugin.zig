const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("sdk");
const protocol = @import("protocol.zig");
const abi = sdk.abi;

comptime {
    if (!builtin.is_test) _ = @import("rt");
}

pub const panic = sdk.panic;

const max_devices = 8;
const max_name_len = 63;
const max_id_len = 15;
const max_zones = protocol.max_zone_count;
const max_leds = protocol.max_led_count;

const ZoneState = struct {
    info: abi.ZoneInfo = .{ .name = null, .led_count = 0, .max_leds = 0 },
    colors: [max_leds]abi.Rgb = [_]abi.Rgb{abi.Rgb.black} ** max_leds,
    dirty: bool = false,
    host_streamed: bool = false,
    mode_pending: bool = true,
    legacy_mode: u8 = 0x01,

    fn reset(self: *ZoneState, spec: protocol.ZoneSpec) void {
        self.* = .{
            .info = .{
                .flags = abi.zone_host_frames,
                .name = spec.name,
                .led_count = spec.led_count,
                .max_leds = spec.led_count,
                .hw_effects = protocol.hwEffects(.legacy),
                .hw_max_colors = 1,
            },
        };
    }
};

const Device = struct {
    handle: sdk.nvapi.GpuHandle,
    identity: protocol.PciIdentity,
    family: protocol.ProtocolFamily,
    layout: protocol.ZoneLayout,
    address: u7,
    lost: bool = false,
    id_buffer: [max_id_len + 1]u8 = [_]u8{0} ** (max_id_len + 1),
    name_buffer: [max_name_len + 1]u8 = [_]u8{0} ** (max_name_len + 1),
    zone_storage: [max_zones]ZoneState = [_]ZoneState{.{}} ** max_zones,
    zone_pointers: [max_zones]*const abi.ZoneInfo = undefined,
    info: abi.DeviceInfo = .{ .zone_count = 0, .id = null, .name = null, .zones = null, .max_fps = protocol.device_max_fps },

    fn resetZones(self: *Device, name: []const u8) void {
        const display_name = if (name.len == 0) "Gigabyte GPU" else name[0..@min(name.len, max_name_len)];
        @memset(&self.name_buffer, 0);
        @memcpy(self.name_buffer[0..display_name.len], display_name);
        for (protocol.zones(self.layout), 0..) |spec, index| {
            self.zone_storage[index].reset(spec);
            self.zone_storage[index].info.hw_effects = protocol.hwEffects(self.family);
        }
    }

    fn link(self: *Device, id: []const u8) void {
        @memset(&self.id_buffer, 0);
        @memcpy(self.id_buffer[0..id.len], id);
        const specs = protocol.zones(self.layout);
        for (0..specs.len) |index| self.zone_pointers[index] = &self.zone_storage[index].info;
        self.info = .{
            .zone_count = @intCast(specs.len),
            .id = @ptrCast(&self.id_buffer),
            .name = @ptrCast(&self.name_buffer),
            .zones = &self.zone_pointers,
            .max_fps = protocol.device_max_fps,
        };
    }

    fn anyHostStreamed(self: *const Device) bool {
        for (self.zone_storage[0..self.info.zone_count]) |zone| {
            if (zone.host_streamed) return true;
        }
        return false;
    }

    fn markResume(self: *Device) void {
        for (self.zone_storage[0..self.info.zone_count]) |*zone| {
            zone.mode_pending = true;
            zone.dirty = zone.host_streamed;
        }
    }
};

const Candidate = struct {
    handle: sdk.nvapi.GpuHandle,
    identity: protocol.PciIdentity,
};

const Instance = struct {
    host: sdk.HostApi,
    nvapi: ?sdk.nvapi.Nvapi = null,
    devices: [max_devices]Device = undefined,
    device_count: usize = 0,

    fn discover(self: *Instance, reprobe_present: bool) i32 {
        var api = &(self.nvapi orelse return abi.status_ok);
        var handles: [sdk.nvapi.max_gpus]?sdk.nvapi.GpuHandle = undefined;
        const count = api.gpus(&handles);
        var candidates: [max_devices]Candidate = undefined;
        var candidate_count: usize = 0;
        for (handles[0..count]) |maybe_handle| {
            const handle = maybe_handle orelse continue;
            const pci = api.pciIds(handle) orelse continue;
            const identity = protocol.PciIdentity{ .device_id = pci.device(), .subvendor_id = pci.subvendor(), .subdevice_id = pci.subdevice(), .revision = pci.revision };
            if (protocol.lookup(identity, .legacy) == null and protocol.lookup(identity, .blackwell) == null) {
                logSkippedGpu(self.host, identity);
                continue;
            }
            if (candidate_count == max_devices) break;
            candidates[candidate_count] = .{ .handle = handle, .identity = identity };
            candidate_count += 1;
        }
        std.sort.insertion(Candidate, candidates[0..candidate_count], {}, candidateLessThan);
        var fresh: [max_devices]Device = undefined;
        var fresh_count: usize = 0;
        for (candidates[0..candidate_count]) |candidate| {
            if (!reprobe_present) {
                if (self.findPresent(candidate)) |index| {
                    fresh[fresh_count] = self.devices[index];
                    fresh_count += 1;
                    continue;
                }
            }
            const probed = self.probe(candidate) orelse continue;
            var name_buffer: [64]u8 = undefined;
            fresh[fresh_count] = .{ .handle = candidate.handle, .identity = candidate.identity, .family = probed.model.family, .layout = probed.model.layout, .address = probed.address };
            fresh[fresh_count].resetZones(api.fullName(candidate.handle, &name_buffer));
            fresh_count += 1;
        }
        const changed = !sameDevices(self.devices[0..self.device_count], fresh[0..fresh_count]);
        @memcpy(self.devices[0..fresh_count], fresh[0..fresh_count]);
        self.device_count = fresh_count;
        assignIds(self.devices[0..fresh_count]);
        return if (changed) abi.rescan_changed else abi.status_ok;
    }

    fn findPresent(self: *Instance, candidate: Candidate) ?usize {
        for (self.devices[0..self.device_count], 0..) |device, index| {
            if (!device.lost and device.handle == candidate.handle and sameIdentity(device.identity, candidate.identity)) return index;
        }
        return null;
    }

    const Probed = struct {
        model: protocol.DeviceModel,
        address: u7,
    };

    fn probe(self: *Instance, candidate: Candidate) ?Probed {
        if (self.tryProbe(candidate, .blackwell)) |model| return .{ .model = model, .address = protocol.blackwell_address };
        if (self.tryProbe(candidate, .legacy)) |model| return .{ .model = model, .address = protocol.legacy_address };
        return null;
    }

    fn tryProbe(self: *Instance, candidate: Candidate, family: protocol.ProtocolFamily) ?protocol.DeviceModel {
        const model = protocol.lookup(candidate.identity, family) orelse return null;
        var api = &self.nvapi.?;
        switch (family) {
            .legacy => {
                var response: [4]u8 = undefined;
                const request = protocol.buildLegacyProbe();
                if (!api.writeThenRead(candidate.handle, protocol.legacy_address, &request, &response)) return null;
                if (!protocol.parseLegacyProbe(&response)) return null;
                return model;
            },
            .blackwell => {
                var response: [4]u8 = undefined;
                const request10 = protocol.buildBlackwellProbe10();
                if (!api.writeThenRead(candidate.handle, protocol.blackwell_address, &request10, &response)) return null;
                if (!protocol.parseBlackwellProbe10(&response)) return null;
                const request11 = protocol.buildBlackwellSubsystemProbe();
                if (!api.writeThenRead(candidate.handle, protocol.blackwell_address, &request11, &response)) return null;
                if (!protocol.parseBlackwellSubsystem(&response, candidate.identity.subdevice_id)) return null;
                return model;
            },
        }
    }

    fn write(self: *Instance, device: *Device, bytes: []const u8) i32 {
        var api = &self.nvapi.?;
        if (!api.write(device.handle, device.address, bytes)) {
            self.host.logMessage(.warn, "GPU RGB I2C write failed");
            device.lost = true;
            return abi.status_device_lost;
        }
        return abi.status_ok;
    }
};

fn assignIds(devices: []Device) void {
    for (devices, 0..) |*device, index| {
        var id_buffer: [max_id_len + 1]u8 = undefined;
        var ordinal: usize = 0;
        while (true) : (ordinal += 1) {
            const candidate_id = protocol.deviceId(&id_buffer, index, device.identity.subdevice_id, ordinal);
            if (!idTaken(devices[0..index], candidate_id)) {
                device.link(candidate_id);
                break;
            }
        }
    }
}

fn idTaken(earlier: []const Device, id: []const u8) bool {
    for (earlier) |*device| {
        if (std.mem.eql(u8, std.mem.sliceTo(&device.id_buffer, 0), id)) return true;
    }
    return false;
}

fn candidateLessThan(_: void, left: Candidate, right: Candidate) bool {
    return protocol.compareIdentity({}, left.identity, right.identity);
}

fn sameDevices(left: []const Device, right: []const Device) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_device, right_device| {
        if (!sameIdentity(left_device.identity, right_device.identity)) return false;
        if (left_device.family != right_device.family) return false;
    }
    return true;
}

fn sameIdentity(left: protocol.PciIdentity, right: protocol.PciIdentity) bool {
    return left.device_id == right.device_id and left.subvendor_id == right.subvendor_id and left.subdevice_id == right.subdevice_id and left.revision == right.revision;
}

fn logSkippedGpu(host: sdk.HostApi, identity: protocol.PciIdentity) void {
    var buffer: [64]u8 = undefined;
    var index = appendText(&buffer, 0, "skipping GPU PCI ");
    index = appendHex16(&buffer, index, identity.device_id);
    index = appendText(&buffer, index, ":");
    index = appendHex16(&buffer, index, identity.subvendor_id);
    index = appendText(&buffer, index, ":");
    index = appendHex16(&buffer, index, identity.subdevice_id);
    host.logMessage(.debug, buffer[0..index]);
}

fn appendText(buffer: []u8, start: usize, text: []const u8) usize {
    @memcpy(buffer[start .. start + text.len], text);
    return start + text.len;
}

fn appendHex16(buffer: []u8, start: usize, value: u16) usize {
    const digits = "0123456789ABCDEF";
    buffer[start] = digits[(value >> 12) & 0xF];
    buffer[start + 1] = digits[(value >> 8) & 0xF];
    buffer[start + 2] = digits[(value >> 4) & 0xF];
    buffer[start + 3] = digits[value & 0xF];
    return start + 4;
}

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
    self.nvapi = sdk.nvapi.Nvapi.load() catch |err| {
        switch (err) {
            error.NotInstalled => self.host.logMessage(.debug, "NVAPI unavailable (no NVIDIA driver); gigabyte_gpu has nothing to do"),
            error.BusLockUnavailable => self.host.logMessage(.warn, "the NVAPI I2C lock Local\\rgbctrl.nvapi.i2c cannot be created; GPU lighting stays off"),
            error.MissingFunction, error.InitializeFailed => self.host.logMessage(.warn, "NVAPI could not be initialized; GPU lighting stays off"),
        }
        instance_out.* = self;
        return abi.status_ok;
    };
    _ = self.discover(true);
    instance_out.* = self;
    return abi.status_ok;
}

fn close(pointer: ?*anyopaque, reason: u32) callconv(.c) void {
    _ = reason;
    const self = instanceFrom(pointer);
    if (self.nvapi) |*api| api.deinit();
    std.heap.page_allocator.destroy(self);
}

fn deviceCount(pointer: ?*anyopaque) callconv(.c) u32 {
    return @intCast(instanceFrom(pointer).device_count);
}

fn deviceInfo(pointer: ?*anyopaque, device_index: u32) callconv(.c) ?*const abi.DeviceInfo {
    const self = instanceFrom(pointer);
    if (device_index >= self.device_count) return null;
    return &self.devices[device_index].info;
}

fn setHwEffect(pointer: ?*anyopaque, device_index: u32, zone_index: u32, effect: *const abi.HwEffect) callconv(.c) i32 {
    const self = instanceFrom(pointer);
    if (device_index >= self.device_count) return abi.status_argument;
    var device = &self.devices[device_index];
    if (zone_index >= device.info.zone_count) return abi.status_argument;
    const effect_kind = effect.effectKind() orelse return abi.status_argument;
    var zone = &device.zone_storage[zone_index];
    switch (device.family) {
        .legacy => {
            const packet = protocol.buildLegacyModePacket(protocol.zones(device.layout)[zone_index].legacy_index, effect_kind, effect.speed, effect.brightness) orelse return abi.status_unsupported;
            const status = self.write(device, &packet);
            if (status != abi.status_ok) return status;
            zone.legacy_mode = protocol.legacyMode(effect_kind) orelse 0x01;
            if (effect_kind == .off or effect_kind == .static or effect_kind == .breathing or effect_kind == .flash) {
                var color_buffer = [1]abi.Rgb{if (effect_kind == .off) abi.Rgb.black else effect.color(0)};
                const color_packet = protocol.buildLegacyColorPacket(protocol.zones(device.layout)[zone_index], &color_buffer, zone.legacy_mode);
                const color_status = self.write(device, &color_packet);
                if (color_status != abi.status_ok) return color_status;
            }
        },
        .blackwell => {
            const packet = protocol.buildBlackwellHardwarePacket(protocol.zones(device.layout)[zone_index].blackwell_index, effect_kind, effect.speed, effect.brightness, effect.color(0), @intCast(zone.info.led_count)) orelse return abi.status_unsupported;
            const status = self.write(device, &packet);
            if (status != abi.status_ok) return status;
        },
    }
    zone.host_streamed = false;
    zone.mode_pending = false;
    zone.dirty = false;
    return abi.status_ok;
}

fn setLeds(pointer: ?*anyopaque, device_index: u32, zone_index: u32, colors: [*]const abi.Rgb, count: u32) callconv(.c) i32 {
    const self = instanceFrom(pointer);
    if (device_index >= self.device_count) return abi.status_argument;
    var device = &self.devices[device_index];
    if (zone_index >= device.info.zone_count) return abi.status_argument;
    var zone = &device.zone_storage[zone_index];
    const copied_count: usize = @min(count, zone.info.led_count);
    var changed = false;
    for (0..copied_count) |index| {
        changed = changed or !abi.Rgb.eql(zone.colors[index], colors[index]);
        zone.colors[index] = colors[index];
    }
    for (copied_count..zone.info.led_count) |index| {
        changed = changed or !abi.Rgb.eql(zone.colors[index], abi.Rgb.black);
        zone.colors[index] = abi.Rgb.black;
    }
    zone.host_streamed = true;
    zone.dirty = zone.dirty or changed or zone.mode_pending;
    return abi.status_ok;
}

fn flush(pointer: ?*anyopaque, device_index: u32) callconv(.c) i32 {
    const self = instanceFrom(pointer);
    if (device_index >= self.device_count) return abi.status_argument;
    var device = &self.devices[device_index];
    const specs = protocol.zones(device.layout);
    for (device.zone_storage[0..device.info.zone_count], 0..) |*zone, zone_index| {
        if (!zone.host_streamed or !zone.dirty) continue;
        switch (device.family) {
            .legacy => {
                if (zone.mode_pending) {
                    const mode_packet = protocol.buildLegacyModePacket(specs[zone_index].legacy_index, .static, 50, 100).?;
                    const mode_status = self.write(device, &mode_packet);
                    if (mode_status != abi.status_ok) return mode_status;
                    zone.legacy_mode = 0x01;
                    zone.mode_pending = false;
                }
                const packet = protocol.buildLegacyColorPacket(specs[zone_index], zone.colors[0..zone.info.led_count], zone.legacy_mode);
                const status = self.write(device, &packet);
                if (status != abi.status_ok) return status;
            },
            .blackwell => {
                const packet = protocol.buildBlackwellHostPacket(specs[zone_index].blackwell_index, zone.colors[0..zone.info.led_count], @intCast(zone.info.led_count));
                const status = self.write(device, &packet);
                if (status != abi.status_ok) return status;
                zone.mode_pending = false;
            },
        }
        zone.dirty = false;
    }
    return abi.status_ok;
}

fn rescan(pointer: ?*anyopaque, reason: u32) callconv(.c) i32 {
    const self = instanceFrom(pointer);
    switch (reason) {
        abi.rescan_resume => {
            for (self.devices[0..self.device_count]) |*device| device.markResume();
            return abi.status_ok;
        },
        abi.rescan_recover => return self.discover(false),
        else => return abi.status_ok,
    }
}

fn persist(pointer: ?*anyopaque, device_index: u32) callconv(.c) i32 {
    const self = instanceFrom(pointer);
    if (device_index >= self.device_count) return abi.status_argument;
    var device = &self.devices[device_index];
    if (device.anyHostStreamed()) return abi.status_busy;
    switch (device.family) {
        .legacy => {
            const packet = protocol.buildLegacyPersistPacket();
            return self.write(device, &packet);
        },
        .blackwell => {
            const packet = protocol.buildBlackwellPersistPacket();
            return self.write(device, &packet);
        },
    }
}

const plugin = abi.Plugin{
    .name = "gigabyte_gpu",
    .version = "0.1.0",
    .transports = abi.transport_i2c,
    .open = open,
    .close = close,
    .device_count = deviceCount,
    .device_info = deviceInfo,
    .set_hw_effect = setHwEffect,
    .set_leds = setLeds,
    .flush = flush,
    .rescan = rescan,
    .persist = persist,
};

export fn rgbctrl_plugin_entry(host_abi_version: u32) callconv(.c) ?*const abi.Plugin {
    if (host_abi_version < 1) return null;
    return &plugin;
}

test {
    _ = protocol;
}

test "device info pointers refer to the device's own storage after the device moves" {
    var devices: [2]Device = undefined;
    devices[0] = .{ .handle = @ptrFromInt(0x1000), .identity = .{ .device_id = 0x2C02, .subvendor_id = 0x1458, .subdevice_id = 0x418C, .revision = 0 }, .family = .blackwell, .layout = .blackwell_master_5080, .address = protocol.blackwell_address };
    devices[0].resetZones("AORUS RTX 5080");
    devices[0].link("gpu");
    devices[1] = devices[0];
    devices[1].link("gpu_418c");
    try std.testing.expectEqual(@intFromPtr(&devices[1].id_buffer), @intFromPtr(devices[1].info.id.?));
    try std.testing.expectEqual(@intFromPtr(&devices[1].name_buffer), @intFromPtr(devices[1].info.name.?));
    try std.testing.expectEqual(@intFromPtr(&devices[1].zone_pointers), @intFromPtr(devices[1].info.zones.?));
    for (0..devices[1].info.zone_count) |index| {
        try std.testing.expectEqual(@intFromPtr(&devices[1].zone_storage[index].info), @intFromPtr(devices[1].info.zones.?[index]));
    }
    try std.testing.expectEqualStrings("gpu_418c", std.mem.span(devices[1].info.id.?));
    try std.testing.expectEqualStrings("AORUS RTX 5080", std.mem.span(devices[1].info.name.?));
    try std.testing.expectEqual(@as(u32, 6), devices[1].info.zone_count);
}

test "device ids stay unique when different cards share a subsystem id" {
    var devices: [3]Device = undefined;
    const identities = [_]protocol.PciIdentity{
        .{ .device_id = 0x2B85, .subvendor_id = 0x1458, .subdevice_id = 0x416E, .revision = 0 },
        .{ .device_id = 0x2B85, .subvendor_id = 0x1458, .subdevice_id = 0x4176, .revision = 0 },
        .{ .device_id = 0x2C02, .subvendor_id = 0x1458, .subdevice_id = 0x4176, .revision = 0 },
    };
    for (&devices, identities) |*device, identity| {
        device.* = .{ .handle = @ptrFromInt(0x1000), .identity = identity, .family = .legacy, .layout = .legacy, .address = protocol.legacy_address };
        device.resetZones("");
    }
    assignIds(&devices);
    try std.testing.expectEqualStrings("gpu", std.mem.span(devices[0].info.id.?));
    try std.testing.expectEqualStrings("gpu_4176", std.mem.span(devices[1].info.id.?));
    try std.testing.expectEqualStrings("gpu_4176_2", std.mem.span(devices[2].info.id.?));
}
