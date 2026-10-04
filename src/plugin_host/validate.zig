const std = @import("std");
const formatting = @import("../diag/format.zig");
const sdk = @import("sdk");

const abi = sdk.abi;

pub const max_devices = 64;
const max_zones = 64;
const max_leds = 4096;
const max_name_length = 127;

pub const ZoneMeta = struct {
    name: []const u8,
    flags: u32,
    led_count: u32,
    max_leds: u32,
    hw_effects: u32,
    hw_max_colors: u32,
    led_x: ?[]const u16,
};

pub const DeviceMeta = struct {
    index: u32,
    id: []const u8,
    name: []const u8,
    max_fps: u32,
    zones: []const ZoneMeta,
};

pub const Capabilities = struct {
    set_leds: bool,
    set_hw_effect: bool,
    set_zone_size: bool,
};

fn isValidId(text: []const u8) bool {
    if (text.len == 0 or text.len > 31) return false;
    for (text) |char| {
        if (!(std.ascii.isLower(char) or std.ascii.isDigit(char) or char == '_')) return false;
    }
    return true;
}

pub fn boundedString(pointer: ?[*:0]const u8, max_length: usize) ?[]const u8 {
    const start = pointer orelse return null;
    var length: usize = 0;
    while (length <= max_length) : (length += 1) {
        if (start[length] == 0) return start[0..length];
    }
    return null;
}

fn sanitizedCopy(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]const u8 {
    const copy = try arena.dupe(u8, text);
    for (copy) |*char| {
        if (char.* < 0x20 or char.* == 0x7F) char.* = ' ';
    }
    return copy;
}

const Rejection = struct {
    reason: []const u8,
};

const DeviceOutcome = union(enum) {
    device: DeviceMeta,
    rejected: []const u8,
};

pub fn copyDevice(arena: std.mem.Allocator, index: u32, maybe_info: ?*const abi.DeviceInfo, capabilities: Capabilities) error{OutOfMemory}!DeviceOutcome {
    const info = maybe_info orelse return .{ .rejected = "device_info returned NULL" };
    if (info.struct_size < abi.v1_size.device_info) return .{ .rejected = "device_info struct_size is smaller than ABI v1" };
    const id = boundedString(info.id, 31) orelse return .{ .rejected = "device id is NULL or longer than 31 bytes" };
    if (!isValidId(id)) return .{ .rejected = try formatting.allocPrint(arena, "device id \"{s}\" must use a-z, 0-9 and _", .{id}) };
    const name = boundedString(info.name, max_name_length) orelse return .{ .rejected = "device name is NULL or longer than 127 bytes" };
    if (info.zone_count > max_zones) return .{ .rejected = "device reports more than 64 zones" };
    if (info.zone_count > 0 and info.zones == null) return .{ .rejected = "device reports zones but the zone array is NULL" };
    const zones = try arena.alloc(ZoneMeta, info.zone_count);
    const zone_pointers: [*]const ?*const abi.ZoneInfo = if (info.zone_count > 0) @ptrCast(info.zones.?) else undefined;
    for (zones, 0..) |*zone, zone_index| {
        const zone_info = zone_pointers[zone_index] orelse return .{ .rejected = "zone array contains a NULL entry" };
        if (zone_info.struct_size < abi.v1_size.zone_info) return .{ .rejected = "zone_info struct_size is smaller than ABI v1" };
        const zone_name = boundedString(zone_info.name, 31) orelse return .{ .rejected = "zone name is NULL or longer than 31 bytes" };
        if (!isValidId(zone_name)) return .{ .rejected = try formatting.allocPrint(arena, "zone name \"{s}\" must use a-z, 0-9 and _", .{zone_name}) };
        for (zones[0..zone_index]) |previous| {
            if (std.mem.eql(u8, previous.name, zone_name)) return .{ .rejected = try formatting.allocPrint(arena, "zone name \"{s}\" appears twice", .{zone_name}) };
        }
        var flags = zone_info.flags;
        if (!capabilities.set_leds) flags &= ~abi.zone_host_frames;
        if (!capabilities.set_zone_size) flags &= ~abi.zone_resizable;
        const zone_max = @min(zone_info.max_leds, max_leds);
        const led_count = @min(zone_info.led_count, zone_max);
        var led_x: ?[]const u16 = null;
        if (zone_info.led_x) |positions| {
            if (led_count > 0) led_x = try arena.dupe(u16, positions[0..led_count]);
        }
        zone.* = .{
            .name = try arena.dupe(u8, zone_name),
            .flags = flags,
            .led_count = led_count,
            .max_leds = zone_max,
            .hw_effects = if (capabilities.set_hw_effect) zone_info.hw_effects & ((@as(u32, 1) << abi.effect_count) - 1) else 0,
            .hw_max_colors = zone_info.hw_max_colors,
            .led_x = led_x,
        };
    }
    return .{ .device = .{
        .index = index,
        .id = try arena.dupe(u8, id),
        .name = try sanitizedCopy(arena, name),
        .max_fps = info.max_fps,
        .zones = zones,
    } };
}

const PluginProblem = enum {
    none,
    short_struct,
    abi_version,
    invalid_name,
    invalid_version,
    missing_required_function,
};

pub fn validatePluginTable(table: *const abi.Plugin) PluginProblem {
    if (table.struct_size < abi.v1_size.plugin) return .short_struct;
    if (table.abi_version < 1 or table.abi_version > abi.abi_version) return .abi_version;
    const name = boundedString(table.name, 31) orelse return .invalid_name;
    if (!isValidId(name)) return .invalid_name;
    const version = boundedString(table.version, 31) orelse return .invalid_version;
    if (version.len == 0) return .invalid_version;
    for (version) |char| {
        if (char < 0x21 or char > 0x7E) return .invalid_version;
    }
    if (table.open == null or table.close == null or table.device_count == null or table.device_info == null) return .missing_required_function;
    return .none;
}

pub fn describePluginProblem(problem: PluginProblem) []const u8 {
    return switch (problem) {
        .none => "ok",
        .short_struct => "plugin table struct_size is smaller than ABI v1",
        .abi_version => "plugin reports an unsupported abi_version",
        .invalid_name => "plugin name is missing or not made of a-z, 0-9 and _ (1..31 bytes)",
        .invalid_version => "plugin version is missing or not printable (1..31 bytes)",
        .missing_required_function => "plugin lacks open, close, device_count or device_info",
    };
}

pub fn effectiveTickInterval(interval_ms: u32) u32 {
    if (interval_ms == 0) return 0;
    return @max(interval_ms, 20);
}

const testing = std.testing;

const full_capabilities = Capabilities{ .set_leds = true, .set_hw_effect = true, .set_zone_size = true };

test "ids are 1 to 31 bytes of lowercase letters, digits and underscores" {
    try testing.expect(isValidId("motherboard"));
    try testing.expect(isValidId("gpu2"));
    try testing.expect(isValidId("fan_left"));
    try testing.expect(!isValidId(""));
    try testing.expect(!isValidId("Keyboard"));
    try testing.expect(!isValidId("a.b"));
    try testing.expect(!isValidId(&@as([32]u8, @splat('a'))));
}

test "copyDevice clamps LED counts, copies positions and strips unsupported capabilities" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const positions = [_]u16{ 0, 30000, 65535, 1 };
    const zone = abi.ZoneInfo{ .flags = abi.zone_host_frames | abi.zone_resizable, .name = "strip", .led_count = 9000, .max_leds = 9000, .hw_effects = 0xFFFF_FFFF, .hw_max_colors = 1 };
    const small = abi.ZoneInfo{ .name = "logo", .led_count = 3, .max_leds = 3, .led_x = &positions };
    const zones = [_]*const abi.ZoneInfo{ &zone, &small };
    const info = abi.DeviceInfo{ .zone_count = 2, .id = "virtual", .name = "Virtual\ndevice", .zones = &zones, .max_fps = 10 };
    const outcome = try copyDevice(arena_state.allocator(), 0, &info, .{ .set_leds = false, .set_hw_effect = true, .set_zone_size = true });
    const device = outcome.device;
    try testing.expectEqualStrings("Virtual device", device.name);
    try testing.expectEqual(@as(u32, 4096), device.zones[0].max_leds);
    try testing.expectEqual(@as(u32, 4096), device.zones[0].led_count);
    try testing.expectEqual(abi.zone_resizable, device.zones[0].flags);
    try testing.expectEqual(@as(u32, 0x7F), device.zones[0].hw_effects);
    try testing.expectEqualSlices(u16, positions[0..3], device.zones[1].led_x.?);
}

test "copyDevice rejects invalid ids, missing names, too many zones and duplicate zone names" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expect((try copyDevice(arena, 0, null, full_capabilities)) == .rejected);
    const bad_id = abi.DeviceInfo{ .zone_count = 0, .id = "Bad Id", .name = "x", .zones = null };
    try testing.expect((try copyDevice(arena, 0, &bad_id, full_capabilities)) == .rejected);
    const no_name = abi.DeviceInfo{ .zone_count = 0, .id = "ok", .name = null, .zones = null };
    try testing.expect((try copyDevice(arena, 0, &no_name, full_capabilities)) == .rejected);
    const many = abi.DeviceInfo{ .zone_count = 65, .id = "ok", .name = "x", .zones = null };
    try testing.expect((try copyDevice(arena, 0, &many, full_capabilities)) == .rejected);
    const zone = abi.ZoneInfo{ .name = "same", .led_count = 1, .max_leds = 1 };
    const zones = [_]*const abi.ZoneInfo{ &zone, &zone };
    const duplicate = abi.DeviceInfo{ .zone_count = 2, .id = "ok", .name = "x", .zones = &zones };
    const outcome = try copyDevice(arena, 0, &duplicate, full_capabilities);
    try testing.expect(std.mem.indexOf(u8, outcome.rejected, "appears twice") != null);
    var short = abi.DeviceInfo{ .zone_count = 0, .id = "ok", .name = "x", .zones = null };
    short.struct_size = 32;
    try testing.expect((try copyDevice(arena, 0, &short, full_capabilities)) == .rejected);
}

fn stubOpen(host: *const abi.Host, config: ?*const abi.Json, instance: *?*anyopaque) callconv(.c) i32 {
    _ = host;
    _ = config;
    instance.* = null;
    return 0;
}

fn stubClose(instance: ?*anyopaque, reason: u32) callconv(.c) void {
    _ = instance;
    _ = reason;
}

fn stubCount(instance: ?*anyopaque) callconv(.c) u32 {
    _ = instance;
    return 0;
}

fn stubInfo(instance: ?*anyopaque, index: u32) callconv(.c) ?*const abi.DeviceInfo {
    _ = instance;
    _ = index;
    return null;
}

test "validatePluginTable checks size, version, name and required entry points" {
    var table = abi.Plugin{ .name = "virtual_led", .version = "1.0.0", .open = stubOpen, .close = stubClose, .device_count = stubCount, .device_info = stubInfo };
    try testing.expectEqual(PluginProblem.none, validatePluginTable(&table));
    table.abi_version = 2;
    try testing.expectEqual(PluginProblem.abi_version, validatePluginTable(&table));
    table.abi_version = 0;
    try testing.expectEqual(PluginProblem.abi_version, validatePluginTable(&table));
    table.abi_version = 1;
    table.struct_size = 64;
    try testing.expectEqual(PluginProblem.short_struct, validatePluginTable(&table));
    table.struct_size = @sizeOf(abi.Plugin);
    table.name = "Virtual";
    try testing.expectEqual(PluginProblem.invalid_name, validatePluginTable(&table));
    table.name = "virtual";
    table.version = "1 0";
    try testing.expectEqual(PluginProblem.invalid_version, validatePluginTable(&table));
    table.version = "1";
    table.device_info = null;
    try testing.expectEqual(PluginProblem.missing_required_function, validatePluginTable(&table));
}

test "tick intervals below 20 ms are raised to 20 and zero means never" {
    try testing.expectEqual(@as(u32, 0), effectiveTickInterval(0));
    try testing.expectEqual(@as(u32, 20), effectiveTickInterval(5));
    try testing.expectEqual(@as(u32, 1000), effectiveTickInterval(1000));
}
