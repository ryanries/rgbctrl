const std = @import("std");
const formatting = @import("../diag/format.zig");
const heap = @import("../heap.zig");
const validate = @import("../plugin_host/validate.zig");
const lighting_config = @import("../config/lighting_config.zig");

pub const DeviceSet = struct {
    arena_state: std.heap.ArenaAllocator,
    references: std.atomic.Value(u32),
    serial: u64,
    devices: []const validate.DeviceMeta = &.{},

    pub fn create(serial: u64) error{OutOfMemory}!*DeviceSet {
        const self = try heap.allocator.create(DeviceSet);
        self.* = .{ .arena_state = std.heap.ArenaAllocator.init(heap.allocator), .references = .init(1), .serial = serial };
        return self;
    }

    pub fn arena(self: *DeviceSet) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    pub fn retain(self: *DeviceSet) *DeviceSet {
        _ = self.references.fetchAdd(1, .monotonic);
        return self;
    }

    pub fn release(self: *DeviceSet) void {
        if (self.references.fetchSub(1, .acq_rel) != 1) return;
        self.arena_state.deinit();
        heap.allocator.destroy(self);
    }

    pub fn sameTopology(self: *const DeviceSet, other: *const DeviceSet) bool {
        if (self.devices.len != other.devices.len) return false;
        for (self.devices, other.devices) |a, b| {
            if (a.index != b.index or !std.mem.eql(u8, a.id, b.id) or a.zones.len != b.zones.len) return false;
            for (a.zones, b.zones) |zone_a, zone_b| {
                if (!std.mem.eql(u8, zone_a.name, zone_b.name) or zone_a.flags != zone_b.flags or zone_a.hw_effects != zone_b.hw_effects) return false;
            }
        }
        return true;
    }
};

pub const DevicePlan = struct {
    key: []const u8,
    persist_key: []const u8,
    zones: []const lighting_config.Resolution,
};

pub const BindingGeneration = struct {
    arena_state: std.heap.ArenaAllocator,
    serial: u64,
    device_set_serial: u64,
    frame_rate: u32,
    persist_enabled: bool,
    devices: []const DevicePlan = &.{},

    pub fn create(serial: u64, device_set_serial: u64, frame_rate: u32, persist_enabled: bool) error{OutOfMemory}!*BindingGeneration {
        const self = try heap.allocator.create(BindingGeneration);
        self.* = .{ .arena_state = std.heap.ArenaAllocator.init(heap.allocator), .serial = serial, .device_set_serial = device_set_serial, .frame_rate = frame_rate, .persist_enabled = persist_enabled };
        return self;
    }

    pub fn arena(self: *BindingGeneration) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    pub fn destroy(self: *BindingGeneration) void {
        self.arena_state.deinit();
        heap.allocator.destroy(self);
    }
};

pub fn resolutionEql(first: lighting_config.Resolution, second: lighting_config.Resolution) bool {
    return switch (first) {
        .untouched => second == .untouched,
        .invalid => second == .invalid,
        .spec => |spec| switch (second) {
            .spec => |other| spec.eql(&other),
            else => false,
        },
    };
}

pub fn frameIntervalMs(frame_rate: u32, max_fps: u32) u32 {
    const rate = std.math.clamp(frame_rate, 1, 60);
    var interval: u64 = 1000 / rate;
    if (max_fps > 0) interval = @max(interval, (1000 + @as(u64, max_fps) - 1) / max_fps);
    return @intCast(interval);
}

const Alias = struct {
    key: []const u8,
    collided_with: ?[]const u8 = null,
};

pub fn aliasFor(arena: std.mem.Allocator, plugin_name: []const u8, device_id: []const u8, earlier_ids: []const []const u8) error{OutOfMemory}!Alias {
    for (earlier_ids) |earlier| {
        if (std.mem.eql(u8, earlier, device_id)) {
            return .{ .key = try formatting.allocPrint(arena, "{s}.{s}", .{ plugin_name, device_id }), .collided_with = earlier };
        }
    }
    return .{ .key = device_id };
}

const testing = std.testing;

test "the frame interval honors both the configured frame rate and the device limit" {
    try testing.expectEqual(@as(u32, 33), frameIntervalMs(30, 0));
    try testing.expectEqual(@as(u32, 100), frameIntervalMs(30, 10));
    try testing.expectEqual(@as(u32, 34), frameIntervalMs(60, 30));
    try testing.expectEqual(@as(u32, 1000), frameIntervalMs(0, 0));
    try testing.expectEqual(@as(u32, 16), frameIntervalMs(60, std.math.maxInt(u32)));
}

test "a device id already used by an earlier plugin is addressed as plugin.id" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const earlier = [_][]const u8{ "keyboard", "gpu" };
    const plain = try aliasFor(arena_state.allocator(), "other", "motherboard", &earlier);
    try testing.expectEqualStrings("motherboard", plain.key);
    const collided = try aliasFor(arena_state.allocator(), "virtual_led", "gpu", &earlier);
    try testing.expectEqualStrings("virtual_led.gpu", collided.key);
    try testing.expectEqualStrings("gpu", collided.collided_with.?);
}

test "device sets compare topology by ids, zone names and capabilities" {
    const first = try DeviceSet.create(1);
    defer first.release();
    const second = try DeviceSet.create(2);
    defer second.release();
    const zones = [_]validate.ZoneMeta{.{ .name = "strip", .flags = 4, .led_count = 16, .max_leds = 64, .hw_effects = 3, .hw_max_colors = 1, .led_x = null }};
    const resized = [_]validate.ZoneMeta{.{ .name = "strip", .flags = 4, .led_count = 32, .max_leds = 64, .hw_effects = 3, .hw_max_colors = 1, .led_x = null }};
    const devices_a = [_]validate.DeviceMeta{.{ .index = 0, .id = "virtual", .name = "V", .max_fps = 0, .zones = &zones }};
    const devices_b = [_]validate.DeviceMeta{.{ .index = 0, .id = "virtual", .name = "V", .max_fps = 0, .zones = &resized }};
    first.devices = &devices_a;
    second.devices = &devices_b;
    try testing.expect(first.sameTopology(second));
    const renamed = [_]validate.DeviceMeta{.{ .index = 0, .id = "other", .name = "V", .max_fps = 0, .zones = &zones }};
    second.devices = &renamed;
    try testing.expect(!first.sameTopology(second));
}
