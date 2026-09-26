const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("sdk");
const protocol = @import("protocol.zig");
const abi = sdk.abi;

comptime {
    if (!builtin.is_test) _ = @import("rt");
}

pub const panic = sdk.panic;

extern "kernel32" fn Sleep(milliseconds: u32) callconv(.winapi) void;

const device_id = "keyboard";
const zone_name = "keys";
const max_extra_ids = 16;
const unsolicited_log_interval_ms: u64 = 1000;

const IoError = error{ Unsupported, Busy, Timeout, DeviceLost, Failed };

const PersistedRecord = struct {
    known: bool = false,
    value: protocol.HardwareEffect = .{ .effect = 1, .brightness = 255, .speed = 127, .hue = 0, .saturation = 0 },

    fn reset(self: *PersistedRecord) void {
        self.known = false;
    }

    fn update(self: *PersistedRecord, value: protocol.HardwareEffect) void {
        self.known = true;
        self.value = value;
    }
};

const Instance = struct {
    host: sdk.HostApi,
    device: ?sdk.hid.Device = null,
    present: bool = false,
    verified: bool = false,
    a8_supported: bool = false,
    product_id: u16 = 0,
    path_buffer: [512]u16 = undefined,
    path_len: usize = 0,
    extra_ids: [max_extra_ids]protocol.IdPair = undefined,
    extra_id_count: usize = 0,
    quiesce: protocol.Quiesce = .{},
    discovery_restarts: protocol.DiscoveryRestarts = .{},
    led_count: u16 = 0,
    led_x: [protocol.max_leds]u16 = [_]u16{0} ** protocol.max_leds,
    firmware_by_position: [protocol.max_leds]u8 = [_]u8{0} ** protocol.max_leds,
    pending_by_firmware: [protocol.max_leds]protocol.LedColor = [_]protocol.LedColor{.{ .hue = 0, .saturation = 0, .value = 0 }} ** protocol.max_leds,
    sent_by_firmware: [protocol.max_leds]protocol.LedColor = [_]protocol.LedColor{.{ .hue = 0, .saturation = 0, .value = 0 }} ** protocol.max_leds,
    sent_valid: bool = false,
    frame_dirty: bool = false,
    frame_max_value: u8 = 0,
    sent_max_value: u8 = 0,
    sent_max_valid: bool = false,
    host_streaming: bool = false,
    host_entered: bool = false,
    warned_non_uniform_value: bool = false,
    last_unsolicited_log_ms: u64 = 0,
    ram_known: bool = false,
    ram: protocol.HardwareEffect = .{ .effect = 1, .brightness = 255, .speed = 127, .hue = 0, .saturation = 0 },
    persisted: PersistedRecord = .{},
    zone_pointer: *const abi.ZoneInfo = undefined,
    zone_info: abi.ZoneInfo = .{
        .name = zone_name,
        .led_count = 0,
        .max_leds = protocol.max_leds,
        .hw_effects = abi.effectBit(.off) | abi.effectBit(.static) | abi.effectBit(.breathing) | abi.effectBit(.cycle) | abi.effectBit(.rainbow),
        .hw_max_colors = 1,
    },
    zone_list: [1]*const abi.ZoneInfo = undefined,
    device_info: abi.DeviceInfo = .{
        .zone_count = 1,
        .id = device_id,
        .name = "Keychron keyboard",
        .zones = null,
        .max_fps = 30,
    },

    fn initializePointers(self: *Instance) void {
        self.zone_pointer = &self.zone_info;
        self.zone_list[0] = self.zone_pointer;
        self.device_info.zones = &self.zone_list;
    }

    fn path(self: *Instance) [*:0]const u16 {
        return self.path_buffer[0..self.path_len :0];
    }

    fn readConfig(self: *Instance, config: ?*const abi.Json) void {
        const node = self.host.member(config, "extra_ids") orelse return;
        if (self.host.kind(node) != abi.json_array) {
            self.host.warn("extra_ids must be an array of \"VVVV:PPPP\" strings; ignored", .{});
            return;
        }
        const length = self.host.length(node);
        var index: u32 = 0;
        while (index < length and self.extra_id_count < self.extra_ids.len) : (index += 1) {
            const item = self.host.at(node, index);
            const text = self.host.asString(item) orelse {
                self.host.warn("extra_ids[{d}] must be a \"VVVV:PPPP\" string; ignored", .{index});
                continue;
            };
            const pair = protocol.parseIdPair(text) orelse {
                self.host.warn("extra_ids[{d}] value \"{s}\" is invalid; ignored", .{ index, text });
                continue;
            };
            self.extra_ids[self.extra_id_count] = pair;
            self.extra_id_count += 1;
        }
        if (length > self.extra_ids.len) self.host.warn("extra_ids has more than {d} entries; extra entries ignored", .{self.extra_ids.len});
    }

    fn matchesAllowedId(self: *const Instance, device_path: []const u16, info: sdk.hid.Info) bool {
        if (info.vendor_id == protocol.vendor_id and protocol.isDefaultProduct(info.product_id) and sdk.hid.pathContainsIds(device_path, info.vendor_id, info.product_id)) return true;
        for (self.extra_ids[0..self.extra_id_count]) |pair| {
            if (info.vendor_id == pair.vendor_id and info.product_id == pair.product_id and sdk.hid.pathContainsIds(device_path, pair.vendor_id, pair.product_id)) return true;
        }
        return false;
    }

    fn findDevice(self: *Instance) bool {
        var list = sdk.hid.InterfaceList.init(std.heap.page_allocator) catch {
            self.host.warn("could not enumerate HID interfaces", .{});
            return false;
        };
        defer list.deinit();
        var iterator = list.iterator();
        while (iterator.next()) |candidate| {
            const info = sdk.hid.queryInfo(candidate.ptr) orelse continue;
            if (!self.matchesAllowedId(candidate, info)) continue;
            if (info.usage_page != protocol.usage_page or info.usage != protocol.usage) continue;
            if (info.input_length != protocol.report_length or info.output_length != protocol.report_length) continue;
            if (candidate.len + 1 > self.path_buffer.len) continue;
            @memcpy(self.path_buffer[0..candidate.len], candidate);
            self.path_buffer[candidate.len] = 0;
            self.path_len = candidate.len;
            self.product_id = info.product_id;
            var utf8: [512]u8 = undefined;
            self.host.debug("found Keychron raw HID device at {s} (VID 0x{x:0>4}, PID 0x{x:0>4})", .{ sdk.text.utf16ToUtf8(&utf8, candidate), info.vendor_id, info.product_id });
            return true;
        }
        return false;
    }

    fn openHandle(self: *Instance) IoError!void {
        if (self.device != null) return;
        const opened = sdk.hid.Device.open(self.path(), true) catch |err| {
            switch (err) {
                error.SharingViolation => {
                    self.host.warn("Keychron keyboard is in use by another application", .{});
                    return error.Busy;
                },
                error.NotFound => return error.DeviceLost,
                else => {
                    self.host.warn("could not open Keychron keyboard: {s}", .{@errorName(err)});
                    return error.Failed;
                },
            }
        };
        self.device = opened;
    }

    fn closeHandle(self: *Instance) void {
        if (self.device) |*device| device.close();
        self.device = null;
        self.verified = false;
        self.host_entered = false;
    }

    fn logUnsolicited(self: *Instance, now_ms: u64, payload: []const u8) void {
        if (payload.len == 0 or payload[0] == 0xA3) return;
        if (now_ms -| self.last_unsolicited_log_ms < unsolicited_log_interval_ms) return;
        self.last_unsolicited_log_ms = now_ms;
        var hex: [64]u8 = undefined;
        self.host.debug("drained unsolicited Keychron report {s}", .{sdk.text.hexBytes(&hex, payload[0..@min(payload.len, 8)])});
    }

    fn checkQuiesce(self: *Instance) IoError!void {
        const now_ms = self.host.nowMs();
        switch (self.quiesce.release(now_ms)) {
            .none => return error.Busy,
            .quiet => {},
            .cap => self.host.warn("Keychron timeout quiesce released after the 5 second cap", .{}),
        }
    }

    fn sendRequest(self: *Instance, report: *[protocol.report_length]u8, response: *[protocol.payload_length]u8) IoError!void {
        try self.checkQuiesce();
        var matcher = protocol.RequestMatcher.init(report[1..]) orelse return error.Failed;
        var device = &(self.device orelse return error.DeviceLost);
        device.write(report, protocol.reply_timeout_ms) catch |err| {
            self.host.warn("Keychron write failed: {s} (Win32 error {d})", .{ @errorName(err), device.last_error });
            self.closeHandle();
            return error.DeviceLost;
        };
        const start_ms = self.host.nowMs();
        while (true) {
            const now_ms = self.host.nowMs();
            const elapsed = now_ms -| start_ms;
            if (elapsed >= protocol.reply_timeout_ms) {
                self.quiesce = protocol.Quiesce.start(now_ms);
                return error.Timeout;
            }
            var read_buffer: [protocol.report_length]u8 = undefined;
            const remaining: u32 = @intCast(protocol.reply_timeout_ms - elapsed);
            const read_len = device.read(&read_buffer, remaining) catch |err| {
                if (err == error.Timeout) {
                    const timeout_ms = self.host.nowMs();
                    self.quiesce = protocol.Quiesce.start(timeout_ms);
                    return error.Timeout;
                }
                self.host.warn("Keychron read failed: {s} (Win32 error {d})", .{ @errorName(err), device.last_error });
                self.closeHandle();
                return error.DeviceLost;
            };
            if (read_len != protocol.report_length) continue;
            const payload = protocol.payloadFromReport(&read_buffer) orelse continue;
            switch (matcher.observe(payload)) {
                .matched => {
                    @memcpy(response, payload);
                    return;
                },
                .unsupported => return error.Unsupported,
                .failed => return error.Failed,
                .duplicate => return error.Busy,
                .unrelated => self.logUnsolicited(self.host.nowMs(), payload),
            }
        }
    }

    fn drainReports(self: *Instance, now_ms: u64) void {
        if (self.device == null) return;
        var limit: u8 = 0;
        while (limit < 8) : (limit += 1) {
            var report: [protocol.report_length]u8 = undefined;
            var device = &self.device.?;
            const length = device.read(&report, 0) catch |err| {
                if (err != error.Timeout) {
                    self.host.warn("Keychron drain read failed: {s} (Win32 error {d})", .{ @errorName(err), device.last_error });
                    self.closeHandle();
                }
                return;
            };
            if (length != protocol.report_length) return;
            const payload = protocol.payloadFromReport(&report) orelse return;
            if (self.quiesce.active) self.quiesce.observeReport(now_ms, payload);
            self.logUnsolicited(now_ms, payload);
        }
    }

    fn requestBasic(self: *Instance, command: u8, response: *[protocol.payload_length]u8) IoError!void {
        var report: [protocol.report_length]u8 = undefined;
        protocol.buildBasic(&report, command);
        try self.sendRequest(&report, response);
    }

    fn requestA8(self: *Instance, subcommand: u8, arguments: []const u8, response: *[protocol.payload_length]u8) IoError!void {
        var report: [protocol.report_length]u8 = undefined;
        protocol.buildA8(&report, subcommand, arguments);
        try self.sendRequest(&report, response);
    }

    fn setVia(self: *Instance, value: protocol.ViaValue, first: u8, second: u8) IoError!void {
        var report: [protocol.report_length]u8 = undefined;
        var response: [protocol.payload_length]u8 = undefined;
        protocol.buildViaSet(&report, value, first, second);
        try self.sendRequest(&report, &response);
    }

    fn getVia(self: *Instance, value: protocol.ViaValue, second: *u8) IoError!u8 {
        var report: [protocol.report_length]u8 = undefined;
        var response: [protocol.payload_length]u8 = undefined;
        protocol.buildViaGet(&report, value);
        try self.sendRequest(&report, &response);
        if (value == .color) second.* = response[4];
        return response[3];
    }

    fn saveVia(self: *Instance) IoError!void {
        var report: [protocol.report_length]u8 = undefined;
        var response: [protocol.payload_length]u8 = undefined;
        protocol.buildViaSave(&report);
        try self.sendRequest(&report, &response);
    }

    fn applyHardwareMetadata(self: *Instance, flags: u32, led_count: u16, map: ?protocol.LedMap) void {
        self.led_count = led_count;
        self.zone_info.flags = flags;
        self.zone_info.led_count = led_count;
        self.zone_info.max_leds = protocol.max_leds;
        self.device_info.name = protocol.productName(self.product_id).ptr;
        if (map) |led_map| {
            self.firmware_by_position = led_map.firmware_by_position;
            self.led_x = led_map.led_x;
            self.zone_info.led_x = &self.led_x;
        } else {
            self.zone_info.led_x = null;
            for (0..led_count) |index| self.firmware_by_position[index] = @intCast(index);
        }
    }

    fn discover(self: *Instance) IoError!void {
        try self.openHandle();
        var response: [protocol.payload_length]u8 = undefined;
        self.requestBasic(0x01, &response) catch |err| return self.discoveryFailure(err);
        self.requestBasic(0xA1, &response) catch |err| return self.discoveryFailure(err);
        self.requestBasic(0xA2, &response) catch |err| return self.discoveryFailure(err);
        const rgb_supported = protocol.a2RgbFlag(&response) orelse false;
        var use_a8 = false;
        if (rgb_supported) {
            self.requestA8(0x01, &.{}, &response) catch |err| {
                if (err == error.Unsupported) {
                    use_a8 = false;
                } else {
                    return self.discoveryFailure(err);
                }
            };
            if (response[0] == 0xA8 and response[1] == 0x01 and response[2] == 0) use_a8 = true;
        }
        if (use_a8) {
            self.requestA8(0x05, &.{}, &response) catch |err| return self.discoveryFailure(err);
            const count = protocol.a8LedCount(&response) orelse return error.Failed;
            var builder = protocol.LedMapBuilder.init(count);
            var row: u8 = 0;
            while (row < protocol.row_count) : (row += 1) {
                var row_report: [protocol.report_length]u8 = undefined;
                protocol.buildLedRowRequest(&row_report, row);
                self.sendRequest(&row_report, &response) catch |err| return self.discoveryFailure(err);
                builder.appendRow(&response) catch |err| {
                    self.host.warn("Keychron A8 LED map row {d} is invalid: {s}", .{ row, @errorName(err) });
                    return error.Failed;
                };
            }
            const led_map = builder.finish() catch |err| {
                self.host.warn("Keychron A8 LED map is incomplete: {s}", .{@errorName(err)});
                return error.Failed;
            };
            self.a8_supported = true;
            self.applyHardwareMetadata(abi.zone_host_frames | abi.zone_global_brightness_only, count, led_map);
        } else {
            const count = protocol.defaultLedCount(self.product_id) orelse {
                self.host.warn("Keychron PID 0x{x:0>4} does not support A8 and has no built-in LED count", .{self.product_id});
                return error.Failed;
            };
            self.a8_supported = false;
            self.applyHardwareMetadata(0, count, null);
        }
        self.present = true;
        self.verified = true;
        self.discovery_restarts.recordSuccess();
    }

    fn discoveryFailure(self: *Instance, err: IoError) IoError {
        if (err == error.Timeout) {
            if (self.discovery_restarts.recordFailure()) {
                self.closeHandle();
                return error.DeviceLost;
            }
        }
        return err;
    }

    fn rediscoverIfReady(self: *Instance) i32 {
        if (self.verified or self.path_len == 0) return abi.status_ok;
        self.discover() catch |err| {
            if (err == error.Busy) return abi.status_busy;
            if (err == error.DeviceLost) return abi.status_device_lost;
            return abi.status_ok;
        };
        return abi.rescan_changed;
    }

    fn hardwareEffectFrom(effect: *const abi.HwEffect) ?protocol.HardwareEffect {
        const kind = effect.effectKind() orelse return null;
        const color = effect.color(0);
        const hsv = sdk.color.toHsv(color);
        const mapped_effect: u8 = switch (kind) {
            .off => 0,
            .static => 1,
            .breathing => 2,
            .cycle => 4,
            .rainbow => 5,
            else => return null,
        };
        return .{
            .effect = mapped_effect,
            .brightness = if (kind == .off) 0 else protocol.percentToByte(effect.brightness),
            .speed = protocol.percentToByte(effect.speed),
            .hue = sdk.color.hueByte(hsv.hue),
            .saturation = hsv.saturation,
        };
    }

    fn applyHardwareEffect(self: *Instance, desired: protocol.HardwareEffect) IoError!void {
        if (!self.ram_known or self.ram.effect != desired.effect) {
            try self.setVia(.effect, desired.effect, 0);
            Sleep(protocol.effect_delay_ms);
            try self.setVia(.color, desired.hue, desired.saturation);
            try self.setVia(.speed, desired.speed, 0);
            try self.setVia(.brightness, desired.brightness, 0);
        } else {
            var current_second: u8 = 0;
            const current_hue = try self.getVia(.color, &current_second);
            if (current_hue != desired.hue or current_second != desired.saturation) try self.setVia(.color, desired.hue, desired.saturation);
            const current_speed = try self.getVia(.speed, &current_second);
            if (current_speed != desired.speed) try self.setVia(.speed, desired.speed, 0);
            const current_brightness = try self.getVia(.brightness, &current_second);
            if (current_brightness != desired.brightness) try self.setVia(.brightness, desired.brightness, 0);
        }
        self.ram = desired;
        self.ram_known = true;
    }

    fn enterHostMode(self: *Instance) IoError!void {
        if (self.host_entered) return;
        try self.setVia(.effect, 0x17, 0);
        Sleep(protocol.effect_delay_ms);
        var response: [protocol.payload_length]u8 = undefined;
        try self.requestA8(0x08, &.{0x00}, &response);
        var report: [protocol.report_length]u8 = undefined;
        protocol.buildIndicatorsRequest(&report);
        try self.sendRequest(&report, &response);
        self.host_entered = true;
        self.host_streaming = true;
        self.warned_non_uniform_value = false;
        self.sent_valid = false;
        self.sent_max_valid = false;
    }

    fn flushFrame(self: *Instance) IoError!void {
        if (!self.a8_supported) return error.Unsupported;
        errdefer {
            self.sent_valid = false;
            self.sent_max_valid = false;
        }
        try self.enterHostMode();
        if (!self.sent_max_valid or self.sent_max_value != self.frame_max_value) {
            try self.setVia(.brightness, self.frame_max_value, 0);
            self.sent_max_value = self.frame_max_value;
            self.sent_max_valid = true;
        }
        var start: u16 = 0;
        while (start < self.led_count) : (start += protocol.chunk_leds) {
            const count: u8 = @intCast(@min(@as(u16, protocol.chunk_leds), self.led_count - start));
            var changed = !self.sent_valid;
            var colors: [protocol.chunk_leds]protocol.LedColor = undefined;
            for (0..count) |offset| {
                const firmware_index = start + offset;
                const color = self.pending_by_firmware[firmware_index];
                colors[offset] = color;
                if (!color.eql(self.sent_by_firmware[firmware_index])) changed = true;
            }
            if (changed) {
                var report: [protocol.report_length]u8 = undefined;
                var response: [protocol.payload_length]u8 = undefined;
                protocol.buildLedColorRequest(&report, @intCast(start), colors[0..count]);
                try self.sendRequest(&report, &response);
                for (0..count) |offset| {
                    const firmware_index = start + offset;
                    self.sent_by_firmware[firmware_index] = colors[offset];
                }
            }
        }
        self.sent_valid = true;
        self.frame_dirty = false;
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
    self.initializePointers();
    self.readConfig(config);
    if (!self.findDevice()) {
        self.host.debug("no Keychron raw HID keyboard found", .{});
        instance_out.* = self;
        return abi.status_ok;
    }
    self.discover() catch |err| {
        if (err == error.Busy) {
            std.heap.page_allocator.destroy(self);
            return abi.status_busy;
        }
        if (err == error.DeviceLost) {
            std.heap.page_allocator.destroy(self);
            return abi.status_device_lost;
        }
        self.host.warn("Keychron discovery failed: {s}", .{@errorName(err)});
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
    const self = instanceFrom(pointer);
    return if (self.present and self.verified) 1 else 0;
}

fn deviceInfo(pointer: ?*anyopaque, device_index: u32) callconv(.c) ?*const abi.DeviceInfo {
    const self = instanceFrom(pointer);
    if (!self.present or !self.verified or device_index != 0) return null;
    return &self.device_info;
}

fn setHwEffect(pointer: ?*anyopaque, device_index: u32, zone_index: u32, effect: *const abi.HwEffect) callconv(.c) i32 {
    const self = instanceFrom(pointer);
    if (device_index != 0 or zone_index != 0 or !self.verified) return abi.status_argument;
    const desired = Instance.hardwareEffectFrom(effect) orelse return abi.status_unsupported;
    self.host_streaming = false;
    self.host_entered = false;
    self.frame_dirty = false;
    self.applyHardwareEffect(desired) catch |err| {
        return switch (err) {
            error.Busy => abi.status_busy,
            error.DeviceLost => abi.status_device_lost,
            error.Unsupported => abi.status_unsupported,
            else => abi.status_fail,
        };
    };
    return abi.status_ok;
}

fn setLeds(pointer: ?*anyopaque, device_index: u32, zone_index: u32, colors: [*]const abi.Rgb, count: u32) callconv(.c) i32 {
    const self = instanceFrom(pointer);
    if (device_index != 0 or zone_index != 0 or !self.verified) return abi.status_argument;
    if (!self.a8_supported) return abi.status_unsupported;
    const used_count: u16 = @intCast(@min(count, self.led_count));
    var max_value: u8 = 0;
    var non_uniform_value = false;
    for (0..self.led_count) |index| {
        const input = if (index < used_count) colors[index] else abi.Rgb.black;
        const hsv = sdk.color.toHsv(input);
        const color = protocol.LedColor{ .hue = sdk.color.hueByte(hsv.hue), .saturation = hsv.saturation, .value = hsv.value };
        const firmware_index = self.firmware_by_position[index];
        self.pending_by_firmware[firmware_index] = color;
        max_value = @max(max_value, color.value);
    }
    for (0..self.led_count) |index| {
        const firmware_index = self.firmware_by_position[index];
        if (self.pending_by_firmware[firmware_index].value != max_value) non_uniform_value = true;
    }
    if (max_value > 0 and non_uniform_value and !self.warned_non_uniform_value) {
        self.host.warn("Keychron host frames use global brightness; darker or black keys can render at the brightest level", .{});
        self.warned_non_uniform_value = true;
    }
    self.frame_max_value = max_value;
    self.frame_dirty = true;
    self.host_streaming = true;
    return abi.status_ok;
}

fn flush(pointer: ?*anyopaque, device_index: u32) callconv(.c) i32 {
    const self = instanceFrom(pointer);
    if (device_index != 0 or !self.verified) return abi.status_argument;
    if (!self.frame_dirty) return abi.status_ok;
    self.flushFrame() catch |err| {
        return switch (err) {
            error.Busy => abi.status_busy,
            error.DeviceLost => abi.status_device_lost,
            error.Unsupported => abi.status_unsupported,
            else => abi.status_fail,
        };
    };
    return abi.status_ok;
}

fn tick(pointer: ?*anyopaque, now_ms: u64) callconv(.c) i32 {
    const self = instanceFrom(pointer);
    self.drainReports(now_ms);
    if (self.quiesce.active) {
        switch (self.quiesce.release(now_ms)) {
            .none => return abi.status_ok,
            .quiet => {},
            .cap => self.host.warn("Keychron timeout quiesce released after the 5 second cap", .{}),
        }
    }
    return self.rediscoverIfReady();
}

fn rescan(pointer: ?*anyopaque, reason: u32) callconv(.c) i32 {
    const self = instanceFrom(pointer);
    const was_present = self.present and self.verified;
    if (reason == abi.rescan_hotplug or reason == abi.rescan_recover) {
        if (self.device != null and self.verified) return abi.status_ok;
    }
    self.closeHandle();
    self.present = false;
    if (!self.findDevice()) return if (was_present) abi.rescan_changed else abi.status_ok;
    self.discover() catch |err| {
        return switch (err) {
            error.Busy => abi.status_busy,
            error.DeviceLost => abi.status_device_lost,
            else => abi.status_fail,
        };
    };
    const is_present = self.present and self.verified;
    return if (is_present != was_present or reason == abi.rescan_resume) abi.rescan_changed else abi.status_ok;
}

fn persistFailure(self: *Instance, err: IoError) i32 {
    self.persisted.reset();
    return switch (err) {
        error.Busy => abi.status_busy,
        error.DeviceLost => abi.status_device_lost,
        error.Unsupported => abi.status_unsupported,
        else => abi.status_fail,
    };
}

fn persist(pointer: ?*anyopaque, device_index: u32) callconv(.c) i32 {
    const self = instanceFrom(pointer);
    if (device_index != 0 or !self.verified) return abi.status_argument;
    if (self.host_streaming) return abi.status_busy;
    const current = self.ram;
    const known = self.persisted.known;
    var effect_saved = false;
    if (!known or self.persisted.value.effect != current.effect) {
        self.setVia(.effect, current.effect, 0) catch |err| return persistFailure(self, err);
        self.saveVia() catch |err| return persistFailure(self, err);
        Sleep(protocol.effect_delay_ms);
        effect_saved = true;
    }
    if (!known or self.persisted.value.brightness != current.brightness) {
        self.setVia(.brightness, current.brightness, 0) catch |err| return persistFailure(self, err);
        self.saveVia() catch |err| return persistFailure(self, err);
    }
    if (!known or self.persisted.value.speed != current.speed) {
        self.setVia(.speed, current.speed, 0) catch |err| return persistFailure(self, err);
        self.saveVia() catch |err| return persistFailure(self, err);
    }
    if (!known or self.persisted.value.hue != current.hue or self.persisted.value.saturation != current.saturation) {
        self.setVia(.color, current.hue, current.saturation) catch |err| return persistFailure(self, err);
        self.saveVia() catch |err| return persistFailure(self, err);
    }
    if (effect_saved) {
        self.setVia(.brightness, current.brightness, 0) catch |err| return persistFailure(self, err);
        self.setVia(.speed, current.speed, 0) catch |err| return persistFailure(self, err);
        self.setVia(.color, current.hue, current.saturation) catch |err| return persistFailure(self, err);
    }
    self.persisted.update(current);
    return abi.status_ok;
}

const plugin = abi.Plugin{
    .name = "keychron",
    .version = "0.1.0",
    .tick_interval_ms = 50,
    .transports = abi.transport_hid,
    .open = open,
    .close = close,
    .device_count = deviceCount,
    .device_info = deviceInfo,
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

test "hardware effect conversion maps ABI effects to VIA bytes" {
    const color = abi.Rgb{ .r = 0, .g = 255, .b = 0 };
    const effect = abi.HwEffect{ .effect = @intFromEnum(abi.Effect.static), .speed = 50, .brightness = 100, .color_count = 1, .colors = @ptrCast(&color) };
    const converted = Instance.hardwareEffectFrom(&effect).?;
    try std.testing.expectEqual(@as(u8, 1), converted.effect);
    try std.testing.expectEqual(@as(u8, 127), converted.speed);
    try std.testing.expectEqual(@as(u8, 255), converted.brightness);
    try std.testing.expectEqual(@as(u8, 85), converted.hue);
    try std.testing.expectEqual(@as(u8, 255), converted.saturation);
}

test "hardware effect conversion maps off to zero brightness" {
    const effect = abi.HwEffect{ .effect = @intFromEnum(abi.Effect.off), .speed = 100, .brightness = 100, .color_count = 0, .colors = null };
    const converted = Instance.hardwareEffectFrom(&effect).?;
    try std.testing.expectEqual(@as(u8, 0), converted.effect);
    try std.testing.expectEqual(@as(u8, 0), converted.brightness);
}
