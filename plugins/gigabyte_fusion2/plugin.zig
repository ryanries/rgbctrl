const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("sdk");
const protocol = @import("protocol.zig");
const abi = sdk.abi;

comptime {
    if (!builtin.is_test) _ = @import("rt");
}

pub const panic = sdk.panic;

const feature_timeout_ms: u32 = 500;
const device_id = "motherboard";
const device_name = "Gigabyte X870E AORUS PRO ICE";
const hardware_effects = abi.effectBit(.off) | abi.effectBit(.static) | abi.effectBit(.breathing) | abi.effectBit(.flash) | abi.effectBit(.cycle);

const OpenResult = error{ NotFound, Busy, Access, DeviceLost };

const Instance = struct {
    host: sdk.HostApi,
    device: ?sdk.hid.Device = null,
    present: bool = false,
    path_buffer: [512]u16 = undefined,
    path_len: usize = 0,
    zone_infos: [protocol.zone_count]abi.ZoneInfo = undefined,
    zone_pointers: [protocol.zone_count]*const abi.ZoneInfo = undefined,
    device_info: abi.DeviceInfo = .{ .zone_count = protocol.zone_count, .id = device_id, .name = device_name, .zones = null },
    calibrations: [protocol.zone_count]protocol.Calibration = undefined,
    feature_flags: u8 = 0,
    led_count_class_shadow: [3]u8 = .{ 0, 0, 0 },
    firmware: [28]u8 = [_]u8{0} ** 28,
    firmware_len: usize = 0,
    argb_led_counts: [protocol.argb_zone_count]u32 = [_]u32{0} ** protocol.argb_zone_count,
    argb_resized: [protocol.argb_zone_count]bool = [_]bool{false} ** protocol.argb_zone_count,
    desired_argb: [protocol.argb_zone_count][protocol.max_argb_leds]abi.Rgb = undefined,
    sent_argb: [protocol.argb_zone_count][protocol.max_argb_leds]abi.Rgb = undefined,
    argb_dirty: [protocol.argb_zone_count]bool = [_]bool{false} ** protocol.argb_zone_count,
    argb_sent_valid: [protocol.argb_zone_count]bool = [_]bool{false} ** protocol.argb_zone_count,
    desired_one_led: [protocol.one_led_zone_count]abi.Rgb = [_]abi.Rgb{abi.Rgb.black} ** protocol.one_led_zone_count,
    sent_one_led: [protocol.one_led_zone_count]abi.Rgb = [_]abi.Rgb{abi.Rgb.black} ** protocol.one_led_zone_count,
    one_led_dirty: [protocol.one_led_zone_count]bool = [_]bool{false} ** protocol.one_led_zone_count,
    one_led_sent_valid: [protocol.one_led_zone_count]bool = [_]bool{false} ** protocol.one_led_zone_count,
    one_led_last_write_ms: [protocol.one_led_zone_count]u64 = [_]u64{0} ** protocol.one_led_zone_count,
    host_stream_mask: u8 = 0,
    pending_direct_mask: bool = false,
    first_write_init_pending: bool = true,

    fn initialize(self: *Instance) void {
        for (protocol.zone_specs, 0..) |zone_spec, index| {
            self.zone_pointers[index] = &self.zone_infos[index];
            const is_argb = zone_spec.argb_index != 0xFF;
            self.zone_infos[index] = .{
                .flags = if (is_argb) abi.zone_resizable | abi.zone_host_frames else abi.zone_host_frames,
                .name = zone_spec.name,
                .led_count = if (is_argb) 0 else 1,
                .max_leds = if (is_argb) protocol.max_argb_leds else 1,
                .hw_effects = hardware_effects,
                .hw_max_colors = 1,
            };
        }
        self.device_info.zones = &self.zone_pointers;
        @memset(std.mem.sliceAsBytes(&self.desired_argb), 0);
        @memset(std.mem.sliceAsBytes(&self.sent_argb), 0);
    }

    fn path(self: *Instance) [*:0]const u16 {
        return self.path_buffer[0..self.path_len :0];
    }

    fn findMatchingPath(self: *Instance) bool {
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
            if (info.usage_page != protocol.usage_page or info.usage != protocol.usage) continue;
            if (info.feature_length != protocol.report_length) continue;
            if (candidate.len + 1 > self.path_buffer.len) continue;
            @memcpy(self.path_buffer[0..candidate.len], candidate);
            self.path_buffer[candidate.len] = 0;
            self.path_len = candidate.len;
            var utf8: [512]u8 = undefined;
            self.host.debug("found Gigabyte Fusion2 controller at {s} (version 0x{x:0>4})", .{ sdk.text.utf16ToUtf8(&utf8, candidate), info.version });
            return true;
        }
        return false;
    }

    fn openAndIdentify(self: *Instance) OpenResult!void {
        if (!self.findMatchingPath()) return error.NotFound;
        const device = sdk.hid.Device.open(self.path(), true) catch |err| {
            switch (err) {
                error.SharingViolation => {
                    self.host.warn("in use by another application (close Gigabyte Control Center / RGB Fusion)", .{});
                    return error.Busy;
                },
                error.AccessDenied => return error.Access,
                else => return error.DeviceLost,
            }
        };
        self.device = device;
        self.runIdentification() catch |err| {
            self.closeHandle();
            return err;
        };
        self.present = true;
        self.first_write_init_pending = true;
    }

    fn closeHandle(self: *Instance) void {
        if (self.device) |*device| device.close();
        self.device = null;
    }

    fn deviceLost(self: *Instance, comptime format: []const u8, args: anytype) i32 {
        self.host.warn(format, args);
        self.closeHandle();
        self.present = false;
        return abi.status_device_lost;
    }

    fn setFeature(self: *Instance, packet: *[protocol.report_length]u8) OpenResult!void {
        if (self.device) |*device| {
            device.setFeature(packet) catch |err| {
                self.host.warn("Gigabyte Fusion2 HID feature write failed: {s} (Win32 error {d})", .{ @errorName(err), device.last_error });
                return error.DeviceLost;
            };
            return;
        }
        return error.DeviceLost;
    }

    fn getFeature(self: *Instance, packet: *[protocol.report_length]u8) OpenResult!void {
        if (self.device) |*device| {
            @memset(packet, 0);
            packet[0] = protocol.report_id;
            const transferred = device.getFeature(packet, feature_timeout_ms) catch |err| {
                self.host.warn("Gigabyte Fusion2 HID feature read failed: {s} (Win32 error {d})", .{ @errorName(err), device.last_error });
                return error.DeviceLost;
            };
            if (transferred != protocol.report_length) {
                self.host.warn("Gigabyte Fusion2 HID feature read returned {d} bytes instead of {d}", .{ transferred, protocol.report_length });
                return error.DeviceLost;
            }
            return;
        }
        return error.DeviceLost;
    }

    fn transaction(self: *Instance, command: u8, response: *[protocol.report_length]u8) OpenResult!void {
        var request: [protocol.report_length]u8 = undefined;
        protocol.buildRequest(&request, command);
        try self.setFeature(&request);
        try self.getFeature(response);
    }

    fn runIdentification(self: *Instance) OpenResult!void {
        var info_response: [protocol.report_length]u8 = undefined;
        var extended_response: [protocol.report_length]u8 = undefined;
        try self.transaction(protocol.command_info, &info_response);
        try self.transaction(protocol.command_info_extended, &extended_response);
        const identification = protocol.parseIdentification(&info_response, &extended_response) catch |err| {
            self.host.warn("Gigabyte Fusion2 identification reply was invalid: {s}", .{@errorName(err)});
            return error.DeviceLost;
        };
        self.feature_flags = identification.feature_flags;
        self.led_count_class_shadow = identification.led_count_class_shadow;
        self.firmware = identification.firmware;
        self.firmware_len = identification.firmware_len;
        self.calibrations = identification.calibrations;
        self.applyCapabilities();
        self.first_write_init_pending = true;
    }

    fn applyCapabilities(self: *Instance) void {
        for (protocol.zone_specs, 0..) |zone_spec, index| {
            const calibration = self.calibrations[index];
            const is_argb = zone_spec.argb_index != 0xFF;
            self.zone_infos[index].flags = if (is_argb) abi.zone_resizable | abi.zone_host_frames else abi.zone_host_frames;
            self.zone_infos[index].hw_effects = hardware_effects;
            self.zone_infos[index].hw_max_colors = 1;
            self.zone_infos[index].max_leds = if (is_argb) protocol.max_argb_leds else 1;
            self.zone_infos[index].led_count = if (is_argb) self.argb_led_counts[zone_spec.argb_index] else 1;
            if (!calibration.enabled) {
                self.zone_infos[index].flags = 0;
                self.zone_infos[index].hw_effects = 0;
                self.zone_infos[index].hw_max_colors = 0;
                self.host.warn("zone {s} reported an all-zero calibration word; disabling its capabilities", .{zone_spec.name});
            }
        }
    }

    fn ensureReadyForLighting(self: *Instance) i32 {
        if (!self.present or self.device == null) return abi.status_device_lost;
        if (self.first_write_init_pending) {
            if ((self.feature_flags & 0x02) != 0) {
                var lamp_packet: [protocol.report_length]u8 = undefined;
                protocol.buildSimpleValue(&lamp_packet, protocol.command_lamp_array, 0);
                self.setFeature(&lamp_packet) catch {
                    self.closeHandle();
                    self.present = false;
                    return abi.status_device_lost;
                };
            }
            var beat_packet: [protocol.report_length]u8 = undefined;
            protocol.buildSimpleValue(&beat_packet, protocol.command_beat, 0);
            self.setFeature(&beat_packet) catch {
                self.closeHandle();
                self.present = false;
                return abi.status_device_lost;
            };
            var class_packet: [protocol.report_length]u8 = undefined;
            protocol.buildLedCountClasses(&class_packet, protocol.computeLedCountClasses(self.led_count_class_shadow, self.argb_led_counts, self.argb_resized));
            self.setFeature(&class_packet) catch {
                self.closeHandle();
                self.present = false;
                return abi.status_device_lost;
            };
            self.first_write_init_pending = false;
            self.pending_direct_mask = true;
        }
        if (self.pending_direct_mask) {
            var direct_packet: [protocol.report_length]u8 = undefined;
            protocol.buildDirectMask(&direct_packet, self.host_stream_mask);
            self.setFeature(&direct_packet) catch {
                self.closeHandle();
                self.present = false;
                return abi.status_device_lost;
            };
            sdk.win32.Sleep(50);
            self.pending_direct_mask = false;
        }
        return abi.status_ok;
    }

    fn zoneHasCapabilities(self: *const Instance, zone_index: usize) bool {
        return self.zone_infos[zone_index].hw_effects != 0 or self.zone_infos[zone_index].flags != 0;
    }

    fn writeSlotEffect(self: *Instance, zone: protocol.Zone, effect: protocol.HardwareEffect, speed: u32, brightness: u32, color: abi.Rgb) i32 {
        const ready = self.ensureReadyForLighting();
        if (ready != abi.status_ok) return ready;
        var slot_packet: [protocol.report_length]u8 = undefined;
        protocol.buildSlotPacket(&slot_packet, zone, effect, speed, brightness, color);
        self.setFeature(&slot_packet) catch {
            self.closeHandle();
            self.present = false;
            return abi.status_device_lost;
        };
        var apply_packet: [protocol.report_length]u8 = undefined;
        protocol.buildApply(&apply_packet, protocol.spec(zone).apply_mask);
        self.setFeature(&apply_packet) catch {
            self.closeHandle();
            self.present = false;
            return abi.status_device_lost;
        };
        return abi.status_ok;
    }

    fn flushArgbZone(self: *Instance, argb_index_value: usize) i32 {
        const zone: protocol.Zone = @enumFromInt(argb_index_value);
        if (!self.argb_dirty[argb_index_value]) return abi.status_ok;
        if ((self.host_stream_mask & protocol.spec(zone).direct_mask_bit) == 0) return abi.status_ok;
        const led_count = self.argb_led_counts[argb_index_value];
        if (self.argb_sent_valid[argb_index_value] and rgbSlicesEqual(self.desired_argb[argb_index_value][0..led_count], self.sent_argb[argb_index_value][0..led_count])) {
            self.argb_dirty[argb_index_value] = false;
            return abi.status_ok;
        }
        const ready = self.ensureReadyForLighting();
        if (ready != abi.status_ok) return ready;
        const order = self.calibrations[protocol.zoneIndex(zone)].order;
        var led_offset: usize = 0;
        while (led_offset < led_count) {
            const chunk_leds: usize = @min(protocol.stream_payload_limit / 3, led_count - led_offset);
            var packet: [protocol.report_length]u8 = undefined;
            protocol.buildStreamPacket(&packet, protocol.spec(zone).stream_command, @intCast(led_offset * 3), self.desired_argb[argb_index_value][led_offset .. led_offset + chunk_leds], order);
            self.setFeature(&packet) catch {
                self.closeHandle();
                self.present = false;
                return abi.status_device_lost;
            };
            led_offset += chunk_leds;
        }
        @memcpy(self.sent_argb[argb_index_value][0..led_count], self.desired_argb[argb_index_value][0..led_count]);
        self.argb_sent_valid[argb_index_value] = true;
        self.argb_dirty[argb_index_value] = false;
        return abi.status_ok;
    }

    fn flushOneLedZone(self: *Instance, one_led_index_value: usize, now_ms: u64) i32 {
        if (!self.one_led_dirty[one_led_index_value]) return abi.status_ok;
        if (self.one_led_sent_valid[one_led_index_value] and abi.Rgb.eql(self.desired_one_led[one_led_index_value], self.sent_one_led[one_led_index_value])) {
            self.one_led_dirty[one_led_index_value] = false;
            return abi.status_ok;
        }
        const elapsed = now_ms -| self.one_led_last_write_ms[one_led_index_value];
        if (self.one_led_last_write_ms[one_led_index_value] != 0 and elapsed < protocol.one_led_frame_interval_ms) return abi.status_ok;
        const zone: protocol.Zone = @enumFromInt(protocol.argb_zone_count + one_led_index_value);
        const status = self.writeSlotEffect(zone, .static, 100, 100, self.desired_one_led[one_led_index_value]);
        if (status != abi.status_ok) return status;
        self.sent_one_led[one_led_index_value] = self.desired_one_led[one_led_index_value];
        self.one_led_sent_valid[one_led_index_value] = true;
        self.one_led_dirty[one_led_index_value] = false;
        self.one_led_last_write_ms[one_led_index_value] = now_ms;
        return abi.status_ok;
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

fn rgbSlicesEqual(first: []const abi.Rgb, second: []const abi.Rgb) bool {
    if (first.len != second.len) return false;
    for (first, second) |left, right| {
        if (!abi.Rgb.eql(left, right)) return false;
    }
    return true;
}

fn open(host: *const abi.Host, config: ?*const abi.Json, instance_out: *?*anyopaque) callconv(.c) i32 {
    _ = config;
    panic_host = host;
    sdk.panic.hook = reportPanic;
    const self = std.heap.page_allocator.create(Instance) catch return abi.status_fail;
    self.* = .{ .host = .{ .host = host } };
    self.initialize();
    self.openAndIdentify() catch |err| {
        switch (err) {
            error.NotFound => {
                self.host.debug("no Gigabyte Fusion2 IT5711 controller found", .{});
                instance_out.* = self;
                return abi.status_ok;
            },
            error.Busy => {
                std.heap.page_allocator.destroy(self);
                instance_out.* = null;
                return abi.status_busy;
            },
            error.Access => {
                self.host.warn("could not access Gigabyte Fusion2 IT5711 controller", .{});
                std.heap.page_allocator.destroy(self);
                instance_out.* = null;
                return abi.status_access;
            },
            error.DeviceLost => {
                std.heap.page_allocator.destroy(self);
                instance_out.* = null;
                return abi.status_device_lost;
            },
        }
    };
    instance_out.* = self;
    return abi.status_ok;
}

fn close(pointer: ?*anyopaque, reason: u32) callconv(.c) void {
    _ = reason;
    const self = instanceFrom(pointer);
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

fn setZoneSize(pointer: ?*anyopaque, device_index: u32, zone_index: u32, led_count: u32) callconv(.c) i32 {
    const self = instanceFrom(pointer);
    if (device_index != 0 or zone_index >= protocol.zone_count) return abi.status_argument;
    const zone: protocol.Zone = @enumFromInt(zone_index);
    if (!protocol.isArgb(zone) or !self.zoneHasCapabilities(zone_index)) return abi.status_unsupported;
    if (led_count > protocol.max_argb_leds) return abi.status_argument;
    const argb_index_value = protocol.argbIndex(zone);
    self.argb_led_counts[argb_index_value] = led_count;
    self.argb_resized[argb_index_value] = true;
    self.zone_infos[zone_index].led_count = led_count;
    self.first_write_init_pending = true;
    self.argb_dirty[argb_index_value] = true;
    self.argb_sent_valid[argb_index_value] = false;
    return abi.status_ok;
}

fn setHwEffect(pointer: ?*anyopaque, device_index: u32, zone_index: u32, effect: *const abi.HwEffect) callconv(.c) i32 {
    const self = instanceFrom(pointer);
    if (device_index != 0 or zone_index >= protocol.zone_count) return abi.status_argument;
    if (!self.zoneHasCapabilities(zone_index)) return abi.status_unsupported;
    const zone: protocol.Zone = @enumFromInt(zone_index);
    const hardware_effect: protocol.HardwareEffect = switch (effect.effectKind() orelse return abi.status_unsupported) {
        .off => .off,
        .static => .static,
        .breathing => .breathing,
        .flash => .flash,
        .cycle => .cycle,
        else => return abi.status_unsupported,
    };
    if (protocol.isArgb(zone)) {
        const bit = protocol.spec(zone).direct_mask_bit;
        if ((self.host_stream_mask & bit) != 0) {
            self.host_stream_mask &= ~bit;
            self.pending_direct_mask = true;
        }
        self.argb_dirty[protocol.argbIndex(zone)] = false;
    } else {
        self.one_led_dirty[protocol.oneLedIndex(zone)] = false;
    }
    const color = effect.color(0);
    return self.writeSlotEffect(zone, hardware_effect, effect.speed, effect.brightness, color);
}

fn setLeds(pointer: ?*anyopaque, device_index: u32, zone_index: u32, colors: [*]const abi.Rgb, count: u32) callconv(.c) i32 {
    const self = instanceFrom(pointer);
    if (device_index != 0 or zone_index >= protocol.zone_count) return abi.status_argument;
    if (!self.zoneHasCapabilities(zone_index)) return abi.status_unsupported;
    const zone: protocol.Zone = @enumFromInt(zone_index);
    if ((self.zone_infos[zone_index].flags & abi.zone_host_frames) == 0) return abi.status_unsupported;
    if (protocol.isArgb(zone)) {
        const argb_index_value = protocol.argbIndex(zone);
        const led_count = self.argb_led_counts[argb_index_value];
        if (count > led_count) return abi.status_argument;
        @memcpy(self.desired_argb[argb_index_value][0..count], colors[0..count]);
        if (count < led_count) @memset(self.desired_argb[argb_index_value][count..led_count], abi.Rgb.black);
        self.argb_dirty[argb_index_value] = true;
        const bit = protocol.spec(zone).direct_mask_bit;
        if ((self.host_stream_mask & bit) == 0) {
            self.host_stream_mask |= bit;
            self.pending_direct_mask = true;
        }
        return abi.status_ok;
    }
    if (count == 0) return abi.status_argument;
    const one_led_index_value = protocol.oneLedIndex(zone);
    self.desired_one_led[one_led_index_value] = colors[0];
    self.one_led_dirty[one_led_index_value] = true;
    return abi.status_ok;
}

fn flush(pointer: ?*anyopaque, device_index: u32) callconv(.c) i32 {
    const self = instanceFrom(pointer);
    if (device_index != 0) return abi.status_argument;
    if (!self.present) return abi.status_device_lost;
    for (0..protocol.argb_zone_count) |index| {
        const status = self.flushArgbZone(index);
        if (status != abi.status_ok) return status;
    }
    const now_ms = self.host.nowMs();
    for (0..protocol.one_led_zone_count) |index| {
        const status = self.flushOneLedZone(index, now_ms);
        if (status != abi.status_ok) return status;
    }
    return abi.status_ok;
}

fn tick(pointer: ?*anyopaque, now_ms: u64) callconv(.c) i32 {
    _ = now_ms;
    _ = pointer;
    return abi.status_ok;
}

fn rescan(pointer: ?*anyopaque, reason: u32) callconv(.c) i32 {
    const self = instanceFrom(pointer);
    const was_present = self.present;
    if (reason == abi.rescan_hotplug or reason == abi.rescan_recover) {
        if (self.present and self.device != null) return abi.status_ok;
    }
    if (reason == abi.rescan_resume and self.present and self.device != null) {
        self.runIdentification() catch {
            self.closeHandle();
            self.present = false;
            return abi.status_device_lost;
        };
        self.first_write_init_pending = true;
        return abi.status_ok;
    }
    self.closeHandle();
    self.present = false;
    self.openAndIdentify() catch |err| {
        switch (err) {
            error.NotFound => return if (was_present) abi.rescan_changed else abi.status_ok,
            error.Busy => return abi.status_busy,
            error.Access => return abi.status_access,
            error.DeviceLost => return abi.status_device_lost,
        }
    };
    return if (self.present != was_present) abi.rescan_changed else abi.status_ok;
}

fn persist(pointer: ?*anyopaque, device_index: u32) callconv(.c) i32 {
    const self = instanceFrom(pointer);
    if (device_index != 0) return abi.status_argument;
    if (!self.present or self.device == null) return abi.status_device_lost;
    var packet: [protocol.report_length]u8 = undefined;
    protocol.buildSimpleValue(&packet, protocol.command_persist_flag, 1);
    self.setFeature(&packet) catch {
        self.closeHandle();
        self.present = false;
        return abi.status_device_lost;
    };
    sdk.win32.Sleep(20);
    protocol.buildSimpleValue(&packet, protocol.command_save, 0);
    self.setFeature(&packet) catch {
        self.closeHandle();
        self.present = false;
        return abi.status_device_lost;
    };
    return abi.status_ok;
}

const plugin = abi.Plugin{
    .name = "gigabyte_fusion2",
    .version = "0.1.0",
    .transports = abi.transport_hid,
    .open = open,
    .close = close,
    .device_count = deviceCount,
    .device_info = deviceInfo,
    .set_zone_size = setZoneSize,
    .set_hw_effect = setHwEffect,
    .set_leds = setLeds,
    .flush = flush,
    .tick = tick,
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
