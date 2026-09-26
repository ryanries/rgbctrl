const std = @import("std");
const abi = @import("sdk").abi;

pub const legacy_address: u7 = 0x71;
pub const blackwell_address: u7 = 0x75;
const legacy_packet_length = 8;
const blackwell_packet_length = 64;
pub const max_zone_count = 6;
pub const max_led_count = 8;
pub const device_max_fps = 10;

pub const ProtocolFamily = enum {
    legacy,
    blackwell,
};

pub const ZoneLayout = enum {
    legacy,
    blackwell_master_5080,
};

pub const PciIdentity = struct {
    device_id: u16,
    subvendor_id: u16,
    subdevice_id: u16,
    revision: u32,
};

const AllowlistEntry = struct {
    identity: PciIdentity,
    family: ProtocolFamily,
    layout: ZoneLayout,
};

pub const DeviceModel = struct {
    family: ProtocolFamily,
    layout: ZoneLayout,
};

const allowlist = [_]AllowlistEntry{
    entry(0x2B87, 0x416E, .legacy, .legacy),
    entry(0x2B87, 0x416F, .legacy, .legacy),
    entry(0x2B87, 0x4188, .legacy, .legacy),
    entry(0x2B85, 0x4176, .legacy, .legacy),
    entry(0x2C02, 0x4176, .legacy, .legacy),
    entry(0x2C02, 0x418C, .legacy, .legacy),
    entry(0x2B85, 0x4191, .blackwell, .blackwell_master_5080),
    entry(0x2C02, 0x4174, .blackwell, .blackwell_master_5080),
    entry(0x2C02, 0x4176, .blackwell, .blackwell_master_5080),
    entry(0x2C02, 0x4178, .blackwell, .blackwell_master_5080),
    entry(0x2C02, 0x4179, .blackwell, .blackwell_master_5080),
    entry(0x2C02, 0x417D, .blackwell, .blackwell_master_5080),
    entry(0x2C02, 0x417F, .blackwell, .blackwell_master_5080),
    entry(0x2C02, 0x4180, .blackwell, .blackwell_master_5080),
    entry(0x2C02, 0x4181, .blackwell, .blackwell_master_5080),
    entry(0x2C02, 0x4182, .blackwell, .blackwell_master_5080),
    entry(0x2C02, 0x4184, .blackwell, .blackwell_master_5080),
    entry(0x2C02, 0x4185, .blackwell, .blackwell_master_5080),
    entry(0x2C02, 0x418A, .blackwell, .blackwell_master_5080),
    entry(0x2C02, 0x418B, .blackwell, .blackwell_master_5080),
    entry(0x2C02, 0x418C, .blackwell, .blackwell_master_5080),
    entry(0x2B85, 0x416E, .blackwell, .blackwell_master_5080),
    entry(0x2B85, 0x416F, .blackwell, .blackwell_master_5080),
    entry(0x2B85, 0x4171, .blackwell, .blackwell_master_5080),
    entry(0x2B85, 0x4172, .blackwell, .blackwell_master_5080),
    entry(0x2B85, 0x4199, .blackwell, .blackwell_master_5080),
    entry(0x2B8C, 0x41CA, .blackwell, .blackwell_master_5080),
};

fn entry(device_id: u16, subdevice_id: u16, family: ProtocolFamily, layout: ZoneLayout) AllowlistEntry {
    return .{
        .identity = .{ .device_id = device_id, .subvendor_id = 0x1458, .subdevice_id = subdevice_id, .revision = 0 },
        .family = family,
        .layout = layout,
    };
}

pub fn lookup(identity: PciIdentity, family: ProtocolFamily) ?DeviceModel {
    for (allowlist) |candidate| {
        if (candidate.family == family and candidate.identity.device_id == identity.device_id and candidate.identity.subvendor_id == identity.subvendor_id and candidate.identity.subdevice_id == identity.subdevice_id) {
            return .{ .family = candidate.family, .layout = candidate.layout };
        }
    }
    return null;
}

pub fn compareIdentity(_: void, left: PciIdentity, right: PciIdentity) bool {
    if (left.device_id != right.device_id) return left.device_id < right.device_id;
    if (left.subvendor_id != right.subvendor_id) return left.subvendor_id < right.subvendor_id;
    if (left.subdevice_id != right.subdevice_id) return left.subdevice_id < right.subdevice_id;
    return left.revision < right.revision;
}

pub fn deviceId(buffer: []u8, position: usize, subdevice_id: u16, duplicate_ordinal: usize) []const u8 {
    const hex_digits = "0123456789abcdef";
    @memcpy(buffer[0..3], "gpu");
    if (position == 0) return buffer[0..3];
    buffer[3] = '_';
    for (0..4) |index| {
        const shift: u4 = @intCast(12 - index * 4);
        buffer[4 + index] = hex_digits[(subdevice_id >> shift) & 0xF];
    }
    var length: usize = 8;
    if (duplicate_ordinal > 0) {
        buffer[length] = '_';
        length += 1;
        var digits: [3]u8 = undefined;
        var count: usize = 0;
        var value = @min(duplicate_ordinal + 1, 999);
        while (value > 0) : (value /= 10) {
            digits[count] = '0' + @as(u8, @intCast(value % 10));
            count += 1;
        }
        while (count > 0) {
            count -= 1;
            buffer[length] = digits[count];
            length += 1;
        }
    }
    return buffer[0..length];
}

pub const ZoneSpec = struct {
    name: [*:0]const u8,
    led_count: u8,
    legacy_index: u8,
    blackwell_index: u8,
};

const legacy_zones = [_]ZoneSpec{
    .{ .name = "zones12", .led_count = 2, .legacy_index = 1, .blackwell_index = 0 },
    .{ .name = "zone3", .led_count = 1, .legacy_index = 3, .blackwell_index = 0 },
    .{ .name = "zone4", .led_count = 1, .legacy_index = 4, .blackwell_index = 0 },
    .{ .name = "zone5", .led_count = 1, .legacy_index = 5, .blackwell_index = 0 },
};

const blackwell_master_5080_zones = [_]ZoneSpec{
    .{ .name = "fan_right", .led_count = 8, .legacy_index = 0, .blackwell_index = 0 },
    .{ .name = "fan_left", .led_count = 8, .legacy_index = 0, .blackwell_index = 1 },
    .{ .name = "fan_middle", .led_count = 8, .legacy_index = 0, .blackwell_index = 2 },
    .{ .name = "logo_side", .led_count = 1, .legacy_index = 0, .blackwell_index = 3 },
    .{ .name = "logo_top", .led_count = 1, .legacy_index = 0, .blackwell_index = 4 },
    .{ .name = "extra", .led_count = 1, .legacy_index = 0, .blackwell_index = 5 },
};

pub fn zones(layout: ZoneLayout) []const ZoneSpec {
    return switch (layout) {
        .legacy => &legacy_zones,
        .blackwell_master_5080 => &blackwell_master_5080_zones,
    };
}

pub fn hwEffects(family: ProtocolFamily) u32 {
    _ = family;
    return abi.effectBit(.off) | abi.effectBit(.static) | abi.effectBit(.breathing) | abi.effectBit(.flash) | abi.effectBit(.cycle) | abi.effectBit(.rainbow);
}

pub fn buildLegacyProbe() [legacy_packet_length]u8 {
    return .{ 0xAB, 0, 0, 0, 0, 0, 0, 0 };
}

pub fn parseLegacyProbe(response: []const u8) bool {
    if (response.len < 4) return false;
    if (response[0] != 0xAB) return false;
    return !(response[1] == 0xAB and response[2] == 0xAB and response[3] == 0xAB);
}

pub fn buildBlackwellProbe10() [blackwell_packet_length]u8 {
    var packet: [blackwell_packet_length]u8 = [_]u8{0} ** blackwell_packet_length;
    packet[0] = 0x10;
    packet[1] = 0x01;
    return packet;
}

pub fn parseBlackwellProbe10(response: []const u8) bool {
    if (response.len < 4) return false;
    return response[0] == 0x01 and (response[1] == 0x01 or response[1] == 0x02) and response[2] == 0x01;
}

pub fn buildBlackwellSubsystemProbe() [blackwell_packet_length]u8 {
    var packet: [blackwell_packet_length]u8 = [_]u8{0} ** blackwell_packet_length;
    packet[0] = 0x11;
    packet[1] = 0x01;
    return packet;
}

pub fn parseBlackwellSubsystem(response: []const u8, subdevice_id: u16) bool {
    if (response.len < 4) return false;
    return std.mem.readInt(u16, response[2..4], .big) == subdevice_id;
}

fn legacySpeed(speed: u32) u8 {
    return @intCast((std.math.clamp(speed, 0, 100) * 5 + 50) / 100);
}

fn legacyBrightness(brightness: u32) u8 {
    const clamped = std.math.clamp(brightness, 1, 100);
    return @intCast((clamped * 99 + 50) / 100);
}

fn blackwellSpeed(speed: u32) u8 {
    return 1 + @as(u8, @intCast((std.math.clamp(speed, 0, 100) * 5 + 50) / 100));
}

fn blackwellBrightness(brightness: u32) u8 {
    const clamped = std.math.clamp(brightness, 1, 100);
    return 1 + @as(u8, @intCast(((clamped - 1) * 9 + 49) / 99));
}

pub fn legacyMode(effect: abi.Effect) ?u8 {
    return switch (effect) {
        .off, .static => 0x01,
        .breathing => 0x02,
        .cycle => 0x03,
        .flash => 0x04,
        .rainbow => 0x07,
        .gradient => null,
    };
}

fn blackwellMode(effect: abi.Effect, host_frame: bool) ?u8 {
    if (host_frame) return 0x00;
    return switch (effect) {
        .off => 0x00,
        .static => 0x01,
        .breathing => 0x02,
        .flash => 0x03,
        .cycle => 0x05,
        .rainbow => 0x06,
        .gradient => null,
    };
}

pub fn buildLegacyModePacket(zone: u8, effect: abi.Effect, speed: u32, brightness: u32) ?[legacy_packet_length]u8 {
    const mode = legacyMode(effect) orelse return null;
    const effective_brightness: u8 = if (effect == .breathing) 0x63 else legacyBrightness(brightness);
    return .{ 0x88, mode, legacySpeed(speed), effective_brightness, 0, zone, 0, 0 };
}

fn buildLegacyZones12Packet(colors: []const abi.Rgb, mode: u8) [legacy_packet_length]u8 {
    const first = colorAt(colors, 0);
    const second = colorAt(colors, 1);
    return .{ 0xB0, mode, first.r, first.g, first.b, second.r, second.g, second.b };
}

fn buildLegacyZone3Packet(colors: []const abi.Rgb, mode: u8) [legacy_packet_length]u8 {
    const color = colorAt(colors, 0);
    return .{ 0xB1, mode, color.r, color.g, color.b, 0, 0, 0 };
}

fn buildLegacySingleZonePacket(zone: u8, colors: []const abi.Rgb) [legacy_packet_length]u8 {
    const color = colorAt(colors, 0);
    return .{ 0x40, color.r, color.g, color.b, zone, 0, 0, 0 };
}

pub fn buildLegacyColorPacket(spec: ZoneSpec, colors: []const abi.Rgb, mode: u8) [legacy_packet_length]u8 {
    return switch (spec.legacy_index) {
        1 => buildLegacyZones12Packet(colors, mode),
        3 => buildLegacyZone3Packet(colors, mode),
        else => buildLegacySingleZonePacket(spec.legacy_index, colors),
    };
}

pub fn buildLegacyPersistPacket() [legacy_packet_length]u8 {
    return .{ 0xAA, 0, 0, 0, 0, 0, 0, 0 };
}

fn buildBlackwellPacket(command: u8, zone: u8, mode: u8, speed: u32, brightness: u32, colors: []const abi.Rgb, led_count: u8) [blackwell_packet_length]u8 {
    var packet: [blackwell_packet_length]u8 = [_]u8{0} ** blackwell_packet_length;
    const first = colorAt(colors, 0);
    const count: u8 = @min(led_count, @as(u8, @intCast(@min(colors.len, max_led_count))));
    packet[0] = command;
    packet[1] = 0x01;
    packet[2] = mode;
    packet[3] = blackwellSpeed(speed);
    packet[4] = blackwellBrightness(brightness);
    packet[5] = first.r;
    packet[6] = first.g;
    packet[7] = first.b;
    packet[8] = 0;
    packet[9] = zone;
    packet[10] = count;
    for (0..count) |index| {
        const color = colorAt(colors, index);
        const offset = 11 + index * 3;
        packet[offset] = color.r;
        packet[offset + 1] = color.g;
        packet[offset + 2] = color.b;
    }
    return packet;
}

pub fn buildBlackwellHardwarePacket(zone: u8, effect: abi.Effect, speed: u32, brightness: u32, color: abi.Rgb, led_count: u8) ?[blackwell_packet_length]u8 {
    const mode = blackwellMode(effect, false) orelse return null;
    const fill = if (effect == .off) abi.Rgb.black else color;
    // Repeat the single effect color across the whole zone: the controller lights only the LEDs
    // it is handed a color for, so a multi-LED zone (an 8-LED fan ring) must carry one color per
    // LED or only the first LED lights up.
    const count = @min(led_count, max_led_count);
    var colors_buffer: [max_led_count]abi.Rgb = undefined;
    for (colors_buffer[0..count]) |*slot| slot.* = fill;
    return buildBlackwellPacket(0x12, zone, mode, speed, brightness, colors_buffer[0..count], led_count);
}

pub fn buildBlackwellHostPacket(zone: u8, colors: []const abi.Rgb, led_count: u8) [blackwell_packet_length]u8 {
    return buildBlackwellPacket(0x16, zone, 0x00, 0, 100, colors, led_count);
}

pub fn buildBlackwellPersistPacket() [blackwell_packet_length]u8 {
    var packet: [blackwell_packet_length]u8 = [_]u8{0} ** blackwell_packet_length;
    packet[0] = 0x13;
    packet[1] = 0x01;
    return packet;
}

fn colorAt(colors: []const abi.Rgb, index: usize) abi.Rgb {
    if (colors.len == 0) return abi.Rgb.black;
    if (index < colors.len) return colors[index];
    return colors[0];
}

test "legacy probe accepts firmware replies and rejects echo and short replies" {
    try std.testing.expectEqualSlices(u8, &.{ 0xAB, 0, 0, 0, 0, 0, 0, 0 }, &buildLegacyProbe());
    try std.testing.expect(parseLegacyProbe(&.{ 0xAB, 0x10, 0x52, 0x13 }));
    try std.testing.expect(!parseLegacyProbe(&.{ 0xAB, 0xAB, 0xAB, 0xAB }));
    try std.testing.expect(!parseLegacyProbe(&.{ 0x00, 0x10, 0x52, 0x13 }));
    try std.testing.expect(!parseLegacyProbe(&.{ 0xAB, 0x10, 0x52 }));
}

test "blackwell probes accept only documented signatures and matching subsystem echo" {
    var probe10 = buildBlackwellProbe10();
    try std.testing.expectEqual(@as(u8, 0x10), probe10[0]);
    try std.testing.expectEqual(@as(u8, 0x01), probe10[1]);
    for (probe10[2..]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try std.testing.expect(parseBlackwellProbe10(&.{ 0x01, 0x01, 0x01, 0x10 }));
    try std.testing.expect(parseBlackwellProbe10(&.{ 0x01, 0x02, 0x01, 0x10 }));
    try std.testing.expect(!parseBlackwellProbe10(&.{ 0x01, 0x03, 0x01, 0x10 }));
    try std.testing.expect(!parseBlackwellProbe10(&.{ 0x01, 0x01, 0x00, 0x10 }));
    try std.testing.expect(!parseBlackwellProbe10(&.{ 0x01, 0x01, 0x01 }));
    const subsystem = buildBlackwellSubsystemProbe();
    try std.testing.expectEqual(@as(u8, 0x11), subsystem[0]);
    try std.testing.expectEqual(@as(u8, 0x01), subsystem[1]);
    try std.testing.expect(parseBlackwellSubsystem(&.{ 0x00, 0x00, 0x41, 0x8C }, 0x418C));
    try std.testing.expect(!parseBlackwellSubsystem(&.{ 0x00, 0x00, 0x41, 0x78 }, 0x418C));
    try std.testing.expect(!parseBlackwellSubsystem(&.{ 0x00, 0x00, 0x41 }, 0x418C));
}

test "allowlist requires vendor device subdevice and family" {
    const identity = PciIdentity{ .device_id = 0x2C02, .subvendor_id = 0x1458, .subdevice_id = 0x418C, .revision = 0 };
    try std.testing.expectEqual(ProtocolFamily.legacy, lookup(identity, .legacy).?.family);
    try std.testing.expectEqual(ProtocolFamily.blackwell, lookup(identity, .blackwell).?.family);
    try std.testing.expectEqual(@as(?DeviceModel, null), lookup(.{ .device_id = 0x2C02, .subvendor_id = 0x1234, .subdevice_id = 0x418C, .revision = 0 }, .legacy));
    try std.testing.expectEqual(@as(?DeviceModel, null), lookup(.{ .device_id = 0x2C02, .subvendor_id = 0x1458, .subdevice_id = 0x9999, .revision = 0 }, .blackwell));
}

test "speed and brightness mappings cover legacy and blackwell boundaries" {
    try std.testing.expectEqual(@as(u8, 0), legacySpeed(0));
    try std.testing.expectEqual(@as(u8, 3), legacySpeed(50));
    try std.testing.expectEqual(@as(u8, 5), legacySpeed(100));
    try std.testing.expectEqual(@as(u8, 1), legacyBrightness(1));
    try std.testing.expectEqual(@as(u8, 50), legacyBrightness(50));
    try std.testing.expectEqual(@as(u8, 99), legacyBrightness(100));
    try std.testing.expectEqual(@as(u8, 1), blackwellSpeed(0));
    try std.testing.expectEqual(@as(u8, 4), blackwellSpeed(50));
    try std.testing.expectEqual(@as(u8, 6), blackwellSpeed(100));
    try std.testing.expectEqual(@as(u8, 1), blackwellBrightness(1));
    try std.testing.expectEqual(@as(u8, 5), blackwellBrightness(50));
    try std.testing.expectEqual(@as(u8, 10), blackwellBrightness(100));
}

test "legacy mode packets use required effect codes and breathing brightness" {
    try std.testing.expectEqualSlices(u8, &.{ 0x88, 0x01, 0x03, 0x63, 0, 1, 0, 0 }, &buildLegacyModePacket(1, .static, 50, 100).?);
    try std.testing.expectEqualSlices(u8, &.{ 0x88, 0x02, 0x03, 0x63, 0, 3, 0, 0 }, &buildLegacyModePacket(3, .breathing, 50, 10).?);
    try std.testing.expectEqualSlices(u8, &.{ 0x88, 0x03, 0x05, 0x32, 0, 4, 0, 0 }, &buildLegacyModePacket(4, .cycle, 100, 50).?);
    try std.testing.expectEqualSlices(u8, &.{ 0x88, 0x04, 0x00, 0x01, 0, 5, 0, 0 }, &buildLegacyModePacket(5, .flash, 0, 1).?);
    try std.testing.expectEqualSlices(u8, &.{ 0x88, 0x07, 0x03, 0x63, 0, 1, 0, 0 }, &buildLegacyModePacket(1, .rainbow, 50, 100).?);
    try std.testing.expectEqual(@as(?[legacy_packet_length]u8, null), buildLegacyModePacket(1, .gradient, 50, 100));
}

test "legacy color packets match each zone command shape" {
    const colors = [_]abi.Rgb{ .{ .r = 1, .g = 2, .b = 3 }, .{ .r = 4, .g = 5, .b = 6 } };
    try std.testing.expectEqualSlices(u8, &.{ 0xB0, 0x01, 1, 2, 3, 4, 5, 6 }, &buildLegacyColorPacket(legacy_zones[0], &colors, 0x01));
    try std.testing.expectEqualSlices(u8, &.{ 0xB1, 0x01, 1, 2, 3, 0, 0, 0 }, &buildLegacyColorPacket(legacy_zones[1], colors[0..1], 0x01));
    try std.testing.expectEqualSlices(u8, &.{ 0x40, 1, 2, 3, 4, 0, 0, 0 }, &buildLegacyColorPacket(legacy_zones[2], colors[0..1], 0x01));
    try std.testing.expectEqualSlices(u8, &.{ 0x40, 1, 2, 3, 5, 0, 0, 0 }, &buildLegacyColorPacket(legacy_zones[3], colors[0..1], 0x01));
    try std.testing.expectEqualSlices(u8, &.{ 0xAA, 0, 0, 0, 0, 0, 0, 0 }, &buildLegacyPersistPacket());
}

test "blackwell hardware packet maps effects and uses master 5080 offset eleven" {
    const color = abi.Rgb{ .r = 0x11, .g = 0x22, .b = 0x33 };
    const packet = buildBlackwellHardwarePacket(2, .rainbow, 50, 100, color, 8).?;
    try std.testing.expectEqual(@as(u8, 0x12), packet[0]);
    try std.testing.expectEqual(@as(u8, 0x01), packet[1]);
    try std.testing.expectEqual(@as(u8, 0x06), packet[2]);
    try std.testing.expectEqual(@as(u8, 0x04), packet[3]);
    try std.testing.expectEqual(@as(u8, 0x0A), packet[4]);
    try std.testing.expectEqualSlices(u8, &.{ 0x11, 0x22, 0x33 }, packet[5..8]);
    try std.testing.expectEqual(@as(u8, 2), packet[9]);
    try std.testing.expectEqual(@as(u8, 8), packet[10]);
    try std.testing.expectEqualSlices(u8, &([_]u8{ 0x11, 0x22, 0x33 } ** 8), packet[11..35]);
    try std.testing.expectEqual(@as(?[blackwell_packet_length]u8, null), buildBlackwellHardwarePacket(0, .gradient, 50, 100, color, 8));
}

test "blackwell hardware effect fills every led in the zone" {
    const color = abi.Rgb{ .r = 0x0A, .g = 0x0B, .b = 0x0C };
    // An eight-LED fan ring must be addressed as eight LEDs, not just the first.
    const fan = buildBlackwellHardwarePacket(0, .static, 50, 100, color, 8).?;
    try std.testing.expectEqual(@as(u8, 8), fan[10]);
    try std.testing.expectEqualSlices(u8, &([_]u8{ 0x0A, 0x0B, 0x0C } ** 8), fan[11..35]);
    // A single-LED logo stays a single LED.
    const logo = buildBlackwellHardwarePacket(3, .static, 50, 100, color, 1).?;
    try std.testing.expectEqual(@as(u8, 1), logo[10]);
    try std.testing.expectEqualSlices(u8, &.{ 0x0A, 0x0B, 0x0C }, logo[11..14]);
    // Off blacks out every LED and ignores the requested color.
    const off = buildBlackwellHardwarePacket(0, .off, 50, 100, color, 8).?;
    try std.testing.expectEqual(@as(u8, 8), off[10]);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 24), off[11..35]);
}

test "blackwell host packet carries per led colors and persist packet is padded" {
    const colors = [_]abi.Rgb{
        .{ .r = 1, .g = 2, .b = 3 },
        .{ .r = 4, .g = 5, .b = 6 },
        .{ .r = 7, .g = 8, .b = 9 },
    };
    const packet = buildBlackwellHostPacket(0, &colors, 8);
    try std.testing.expectEqual(@as(u8, 0x16), packet[0]);
    try std.testing.expectEqual(@as(u8, 0x00), packet[2]);
    try std.testing.expectEqual(@as(u8, 0x03), packet[10]);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9 }, packet[11..20]);
    const persist = buildBlackwellPersistPacket();
    try std.testing.expectEqual(@as(u8, 0x13), persist[0]);
    try std.testing.expectEqual(@as(u8, 0x01), persist[1]);
    for (persist[2..]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "device ids stay gpu for the first card and derive the others from the subsystem id" {
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("gpu", deviceId(&buffer, 0, 0x418C, 0));
    try std.testing.expectEqualStrings("gpu_418c", deviceId(&buffer, 1, 0x418C, 0));
    try std.testing.expectEqualStrings("gpu_418c_2", deviceId(&buffer, 1, 0x418C, 1));
    try std.testing.expectEqualStrings("gpu_41ca_3", deviceId(&buffer, 2, 0x41CA, 2));
}
