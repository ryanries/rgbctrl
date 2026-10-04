const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("sdk");
const protocol = @import("protocol.zig");
const abi = sdk.abi;

comptime {
    if (!builtin.is_test) _ = @import("rt");
}

pub const panic = sdk.panic;

const device_id = "apex_pro";
const device_name = "SteelSeries Apex Pro";
const zone_name = "keys";
const max_fps = 30;
const connection_check_interval_ms = 1000;
// The firmware query only feeds the log, so a keyboard that does not answer in time still gets
// its lighting.
const query_write_timeout_ms: u32 = 250;
const query_reply_timeout_ms: u64 = 250;
const max_input_report_length = 128;
const max_drained_reports = 8;

const OpenError = error{ NotFound, Busy, Access, DeviceLost };

const Instance = struct {
    host: sdk.HostApi,
    device: ?sdk.hid.Device = null,
    present: bool = false,
    path_buffer: [512]u16 = undefined,
    path_len: usize = 0,
    input_length: usize = 0,
    frame: [protocol.key_count]abi.Rgb = @splat(abi.Rgb.black),
    frame_pending: bool = false,
    zone_info: abi.ZoneInfo = .{
        .flags = abi.zone_host_frames,
        .name = zone_name,
        .led_count = protocol.key_count,
        .max_leds = protocol.key_count,
        .led_x = &protocol.led_x,
    },
    zone_list: [1]*const abi.ZoneInfo = undefined,
    device_info: abi.DeviceInfo = .{ .zone_count = 1, .id = device_id, .name = device_name, .zones = null, .max_fps = max_fps },

    fn initializePointers(self: *Instance) void {
        self.zone_list[0] = &self.zone_info;
        self.device_info.zones = &self.zone_list;
    }

    fn path(self: *Instance) [*:0]const u16 {
        return self.path_buffer[0..self.path_len :0];
    }

    /// Finds the lighting collection. The other collections with the Apex Pro's USB id are
    /// logged, so a keyboard that describes them differently can be diagnosed.
    fn findDevice(self: *Instance) bool {
        var list = sdk.hid.InterfaceList.init(std.heap.page_allocator) catch {
            self.host.warn("could not enumerate HID interfaces", .{});
            return false;
        };
        defer list.deinit();
        var iterator = list.iterator();
        while (iterator.next()) |candidate| {
            if (!sdk.hid.pathContainsIds(candidate, protocol.vendor_id, protocol.apex_pro_product_id)) continue;
            const info = sdk.hid.queryInfo(candidate.ptr) orelse continue;
            var utf8: [512]u8 = undefined;
            if (!protocol.isLightingCollection(candidate, info)) {
                self.host.debug("skipped Apex Pro HID collection {s}: usage page 0x{x:0>4}, usage 0x{x:0>4}, report lengths in {d}, out {d}, feature {d}", .{ sdk.text.utf16ToUtf8(&utf8, candidate), info.usage_page, info.usage, info.input_length, info.output_length, info.feature_length });
                continue;
            }
            if (candidate.len + 1 > self.path_buffer.len) continue;
            @memcpy(self.path_buffer[0..candidate.len], candidate);
            self.path_buffer[candidate.len] = 0;
            self.path_len = candidate.len;
            self.input_length = info.input_length;
            self.host.debug("found SteelSeries Apex Pro at {s} (version 0x{x:0>4})", .{ sdk.text.utf16ToUtf8(&utf8, candidate), info.version });
            return true;
        }
        return false;
    }

    /// Without an Apex Pro, lists the other SteelSeries HID collections from what Windows reports
    /// about them, without opening them for reading or writing: a keyboard with another USB id
    /// shows up here.
    fn logOtherSteelSeriesCollections(self: *Instance) void {
        const vendor_marker = std.fmt.comptimePrint("vid_{x:0>4}&", .{protocol.vendor_id});
        var list = sdk.hid.InterfaceList.init(std.heap.page_allocator) catch return;
        defer list.deinit();
        var iterator = list.iterator();
        while (iterator.next()) |candidate| {
            if (!sdk.hid.pathContains(candidate, vendor_marker)) continue;
            const info = sdk.hid.queryInfo(candidate.ptr) orelse continue;
            if (info.vendor_id != protocol.vendor_id or info.product_id == protocol.apex_pro_product_id) continue;
            var utf8: [512]u8 = undefined;
            self.host.debug("other SteelSeries HID collection {s}: PID 0x{x:0>4}, usage page 0x{x:0>4}, usage 0x{x:0>4}, report lengths in {d}, out {d}, feature {d}", .{ sdk.text.utf16ToUtf8(&utf8, candidate), info.product_id, info.usage_page, info.usage, info.input_length, info.output_length, info.feature_length });
        }
    }

    fn openAndIdentify(self: *Instance) OpenError!void {
        if (!self.findDevice()) {
            self.logOtherSteelSeriesCollections();
            return error.NotFound;
        }
        self.device = sdk.hid.Device.open(self.path(), true) catch |err| {
            switch (err) {
                error.SharingViolation => {
                    self.host.warn("SteelSeries Apex Pro is in use by another application (close SteelSeries GG)", .{});
                    return error.Busy;
                },
                error.AccessDenied => {
                    self.host.warn("could not access the SteelSeries Apex Pro", .{});
                    return error.Access;
                },
                error.NotFound => return error.NotFound,
                error.Failed => {
                    self.host.warn("could not open the SteelSeries Apex Pro", .{});
                    return error.DeviceLost;
                },
            }
        };
        self.logFirmwareVersion();
        self.present = true;
    }

    fn closeHandle(self: *Instance) void {
        if (self.device) |*device| device.close();
        self.device = null;
    }

    /// Reads the input reports waiting on the handle, which shows whether it still works: the
    /// handle of a keyboard that was unplugged stays dead after the keyboard is plugged back in.
    fn isStillConnected(self: *Instance) bool {
        if (self.device == null) return false;
        const device = &self.device.?;
        var report_buffer: [max_input_report_length]u8 = undefined;
        if (self.input_length < 2 or self.input_length > report_buffer.len) return true;
        const report = report_buffer[0..self.input_length];
        for (0..max_drained_reports) |_| {
            _ = device.read(report, 0) catch |err| {
                if (err == error.Timeout) return true;
                self.host.warn("SteelSeries Apex Pro disconnected: {s} (Win32 error {d})", .{ @errorName(err), device.last_error });
                return false;
            };
        }
        return true;
    }

    /// Asks for the firmware version (read-only) and logs it.
    fn logFirmwareVersion(self: *Instance) void {
        if (self.device == null) return;
        const device = &self.device.?;
        var reply_buffer: [max_input_report_length]u8 = undefined;
        if (self.input_length < 2 or self.input_length > reply_buffer.len) {
            self.host.debug("the Apex Pro has {d}-byte input reports, so its firmware version is not asked", .{self.input_length});
            return;
        }
        const reply = reply_buffer[0..self.input_length];
        // Input reports from before the query would be taken for its answer.
        for (0..max_drained_reports) |_| {
            _ = device.read(reply, 0) catch break;
        }
        var query: [protocol.command_report_length]u8 = undefined;
        protocol.buildFirmwareQuery(&query);
        self.traceReport("output report", &query);
        device.write(&query, query_write_timeout_ms) catch |err| {
            self.host.warn("the Apex Pro did not take the firmware query: {s} (Win32 error {d})", .{ @errorName(err), device.last_error });
            return;
        };
        const start_ms = self.host.nowMs();
        while (true) {
            const elapsed = self.host.nowMs() -| start_ms;
            if (elapsed >= query_reply_timeout_ms) break;
            const length = device.read(reply, @intCast(query_reply_timeout_ms - elapsed)) catch break;
            self.traceReport("input report", reply[0..length]);
            if (protocol.parseFirmwareVersion(reply[0..length])) |version| {
                self.host.info("SteelSeries Apex Pro firmware {s}", .{version});
                return;
            }
        }
        self.host.debug("the Apex Pro did not report its firmware version", .{});
    }

    /// Every frame goes out, even one equal to the last: after sleep or a reconnect the keyboard
    /// shows its own lighting again, and the host re-applies the zone to restore it.
    fn sendFrame(self: *Instance) i32 {
        if (self.device == null) return abi.status_device_lost;
        const device = &self.device.?;
        var report: [protocol.color_report_length]u8 = undefined;
        protocol.buildColorReport(&report, &self.frame);
        self.traceReport("feature report", &report);
        device.setFeature(&report) catch |err| {
            if (err == error.Disconnected) {
                self.host.warn("SteelSeries Apex Pro disconnected (Win32 error {d})", .{device.last_error});
                self.closeHandle();
                self.present = false;
                return abi.status_device_lost;
            }
            self.host.warn("SteelSeries Apex Pro color report failed: {s} (Win32 error {d})", .{ @errorName(err), device.last_error });
            return abi.status_fail;
        };
        self.frame_pending = false;
        return abi.status_ok;
    }

    fn traceReport(self: *Instance, comptime kind: []const u8, report: []const u8) void {
        var hex: [3 * 32]u8 = undefined;
        self.host.trace(kind ++ " {s}", .{sdk.text.hexBytes(&hex, std.mem.trimEnd(u8, report, &.{0}))});
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
    self.initializePointers();
    self.openAndIdentify() catch |err| {
        if (err == error.NotFound) {
            self.host.debug("no SteelSeries Apex Pro (USB 1038:1610) found", .{});
            instance_out.* = self;
            return abi.status_ok;
        }
        std.heap.page_allocator.destroy(self);
        instance_out.* = null;
        return switch (err) {
            error.Busy => abi.status_busy,
            error.Access => abi.status_access,
            error.DeviceLost, error.NotFound => abi.status_device_lost,
        };
    };
    instance_out.* = self;
    return abi.status_ok;
}

// Both kinds of close leave the keyboard on the last colors.
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

fn setLeds(pointer: ?*anyopaque, device_index: u32, zone_index: u32, colors: [*]const abi.Rgb, count: u32) callconv(.c) i32 {
    const self = instanceFrom(pointer);
    if (device_index != 0 or zone_index != 0 or !self.present) return abi.status_argument;
    const used: usize = @min(count, protocol.key_count);
    @memcpy(self.frame[0..used], colors[0..used]);
    @memset(self.frame[used..], abi.Rgb.black);
    self.frame_pending = true;
    return abi.status_ok;
}

fn flush(pointer: ?*anyopaque, device_index: u32) callconv(.c) i32 {
    const self = instanceFrom(pointer);
    if (device_index != 0 or !self.present) return abi.status_argument;
    if (!self.frame_pending) return abi.status_ok;
    return self.sendFrame();
}

/// An effect that does not move is sent once, so a reconnect is noticed here rather than by a
/// failed frame: the keyboard is reported lost, and the host reopens it and applies the zone again.
fn tick(pointer: ?*anyopaque, now_ms: u64) callconv(.c) i32 {
    _ = now_ms;
    const self = instanceFrom(pointer);
    if (!self.present or self.isStillConnected()) return abi.status_ok;
    self.closeHandle();
    self.present = false;
    return abi.status_device_lost;
}

fn rescan(pointer: ?*anyopaque, reason: u32) callconv(.c) i32 {
    const self = instanceFrom(pointer);
    const was_present = self.present;
    if (reason == abi.rescan_hotplug or reason == abi.rescan_recover) {
        if (self.present and self.isStillConnected()) return abi.status_ok;
    }
    const replaced_handle = self.device != null;
    self.closeHandle();
    self.present = false;
    self.openAndIdentify() catch |err| {
        // The host retries a lost device after a resume, but not a busy one, so a keyboard that
        // another program took meanwhile is reported lost and tried again later.
        if (reason == abi.rescan_resume and was_present and (err == error.Busy or err == error.Access)) return abi.status_device_lost;
        return switch (err) {
            error.NotFound => if (was_present) abi.rescan_changed else abi.status_ok,
            error.Busy => abi.status_busy,
            error.Access => abi.status_access,
            error.DeviceLost => abi.status_device_lost,
        };
    };
    // A keyboard on a new handle shows its own lighting until the host applies the zone again.
    return if (self.present != was_present or replaced_handle) abi.rescan_changed else abi.status_ok;
}

const plugin = abi.Plugin{
    .name = "steelseries_apex",
    .version = "0.1.0",
    .tick_interval_ms = connection_check_interval_ms,
    .transports = abi.transport_hid,
    .open = open,
    .close = close,
    .device_count = deviceCount,
    .device_info = deviceInfo,
    .set_leds = setLeds,
    .flush = flush,
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

test "the keyboard is one zone of host frames with a position for every key" {
    var instance: Instance = .{ .host = undefined };
    instance.initializePointers();
    const zone = instance.device_info.zones.?[0];
    try std.testing.expectEqual(abi.zone_host_frames, zone.flags);
    try std.testing.expectEqual(@as(u32, 112), zone.led_count);
    try std.testing.expectEqual(@as(u32, 0), zone.hw_effects);
    try std.testing.expectEqual(@as(u16, protocol.led_x[111]), zone.led_x.?[111]);
    try std.testing.expectEqualStrings("apex_pro", std.mem.span(instance.device_info.id.?));
}

test "a short frame leaves the remaining keys black" {
    var instance: Instance = .{ .host = undefined, .present = true };
    instance.frame = @splat(.{ .r = 9, .g = 9, .b = 9 });
    const colors = [_]abi.Rgb{ .{ .r = 1, .g = 2, .b = 3 }, .{ .r = 4, .g = 5, .b = 6 } };
    try std.testing.expectEqual(abi.status_ok, setLeds(&instance, 0, 0, &colors, colors.len));
    try std.testing.expect(instance.frame_pending);
    try std.testing.expect(instance.frame[1].eql(colors[1]));
    try std.testing.expect(instance.frame[2].eql(abi.Rgb.black));
    try std.testing.expect(instance.frame[111].eql(abi.Rgb.black));
    try std.testing.expectEqual(abi.status_argument, setLeds(&instance, 0, 1, &colors, colors.len));
}

test "the connection check leaves an absent keyboard alone" {
    var instance: Instance = .{ .host = undefined };
    try std.testing.expectEqual(abi.status_ok, tick(&instance, 0));
    try std.testing.expectEqual(@as(u32, 0), deviceCount(&instance));
    try std.testing.expectEqual(@as(u32, connection_check_interval_ms), plugin.tick_interval_ms);
}
