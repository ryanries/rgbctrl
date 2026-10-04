const std = @import("std");
const Rgb = @import("sdk").abi.Rgb;

pub const vendor_id: u16 = 0x048D;
pub const product_id: u16 = 0x5711;
pub const usage_page: u16 = 0xFF89;
pub const usage: u16 = 0x00CC;
pub const report_id: u8 = 0xCC;
pub const report_length = 64;
pub const max_argb_leds = 256;
pub const stream_payload_limit = 57;
pub const one_led_frame_interval_ms: u64 = 67;

pub const command_info: u8 = 0x60;
pub const command_info_extended: u8 = 0x61;
const command_apply: u8 = 0x28;
pub const command_beat: u8 = 0x31;
const command_direct_mask: u8 = 0x32;
const command_led_count_class: u8 = 0x34;
pub const command_persist_flag: u8 = 0x47;
pub const command_lamp_array: u8 = 0x48;
pub const command_save: u8 = 0x5E;

pub const all_zones_mask: u32 = 0x07FF;
/// Every effect slot of the IT5711, including 0x20..0x23 and 0x90, which no zone of this board uses.
pub const effect_slots = [_]u8{ 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x90, 0x91, 0x92 };

pub const Zone = enum(u8) {
    argb1 = 0,
    argb2 = 1,
    argb3 = 2,
    rgb12v = 3,
    io_cover = 4,
    chipset = 5,
};

pub const zone_count = 6;
pub const argb_zone_count = 3;
pub const one_led_zone_count = 3;

pub const HardwareEffect = enum(u32) {
    off = 0,
    static = 1,
    breathing = 2,
    flash = 3,
    cycle = 4,
};

const ZoneSpec = struct {
    zone: Zone,
    name: [:0]const u8,
    slot: u8,
    apply_mask: u32,
    stream_command: u8,
    direct_mask_bit: u8,
    argb_index: u8,
    one_led_index: u8,
};

pub const zone_specs = [_]ZoneSpec{
    .{ .zone = .argb1, .name = "argb1", .slot = 0x25, .apply_mask = 0x020, .stream_command = 0x58, .direct_mask_bit = 0x01, .argb_index = 0, .one_led_index = 0xFF },
    .{ .zone = .argb2, .name = "argb2", .slot = 0x26, .apply_mask = 0x040, .stream_command = 0x59, .direct_mask_bit = 0x02, .argb_index = 1, .one_led_index = 0xFF },
    .{ .zone = .argb3, .name = "argb3", .slot = 0x27, .apply_mask = 0x080, .stream_command = 0x62, .direct_mask_bit = 0x08, .argb_index = 2, .one_led_index = 0xFF },
    .{ .zone = .rgb12v, .name = "rgb12v", .slot = 0x24, .apply_mask = 0x010, .stream_command = 0, .direct_mask_bit = 0, .argb_index = 0xFF, .one_led_index = 0 },
    .{ .zone = .io_cover, .name = "io_cover", .slot = 0x91, .apply_mask = 0x200, .stream_command = 0x64, .direct_mask_bit = 0x20, .argb_index = 0xFF, .one_led_index = 1 },
    .{ .zone = .chipset, .name = "chipset", .slot = 0x92, .apply_mask = 0x400, .stream_command = 0x65, .direct_mask_bit = 0x40, .argb_index = 0xFF, .one_led_index = 2 },
};

const ParseError = error{
    InvalidLength,
    InvalidReport,
    InvalidProduct,
    InvalidExtendedHeader,
    InvalidCalibration,
};

const CalibrationOrder = struct {
    positions: [3]u8,

    fn triplet(self: CalibrationOrder, color: Rgb) [3]u8 {
        var bytes: [3]u8 = undefined;
        bytes[self.positions[0]] = color.b;
        bytes[self.positions[1]] = color.g;
        bytes[self.positions[2]] = color.r;
        return bytes;
    }
};

pub const Calibration = struct {
    enabled: bool,
    order: CalibrationOrder,
};

const Identification = struct {
    firmware: [28]u8,
    firmware_len: usize,
    firmware_version: [4]u8,
    led_count_class_shadow: [3]u8,
    feature_flags: u8,
    calibrations: [zone_count]Calibration,
};

pub fn zoneIndex(zone: Zone) usize {
    return @intFromEnum(zone);
}

pub fn spec(zone: Zone) ZoneSpec {
    return zone_specs[zoneIndex(zone)];
}

pub fn isArgb(zone: Zone) bool {
    return spec(zone).argb_index != 0xFF;
}

pub fn argbIndex(zone: Zone) usize {
    return spec(zone).argb_index;
}

pub fn oneLedIndex(zone: Zone) usize {
    return spec(zone).one_led_index;
}

pub fn buildRequest(packet: *[report_length]u8, command: u8) void {
    @memset(packet, 0);
    packet[0] = report_id;
    packet[1] = command;
}

pub fn buildSimpleValue(packet: *[report_length]u8, command: u8, value: u8) void {
    buildRequest(packet, command);
    packet[2] = value;
}

pub fn buildSlotClear(packet: *[report_length]u8, slot: u8) void {
    buildRequest(packet, slot);
}

pub fn buildApply(packet: *[report_length]u8, mask: u32) void {
    buildRequest(packet, command_apply);
    std.mem.writeInt(u32, packet[2..6], mask, .little);
}

pub fn buildDirectMask(packet: *[report_length]u8, mask: u8) void {
    buildSimpleValue(packet, command_direct_mask, mask);
}

pub fn buildLedCountClasses(packet: *[report_length]u8, classes: [3]u8) void {
    buildRequest(packet, command_led_count_class);
    packet[2] = classes[0];
    packet[3] = classes[1];
    packet[4] = classes[2];
}

fn brightnessByte(brightness: u32, effect: HardwareEffect) u8 {
    const clamped_brightness: u32 = if (brightness > 100) 100 else brightness;
    var value: u32 = clamped_brightness * @as(u32, 255) / 100;
    if (effect == .breathing) value = @min(value, 0x64);
    return @intCast(value);
}

fn speedBucket(speed: u32) usize {
    const clamped_speed: u32 = if (speed > 100) 100 else speed;
    return @intCast(4 - (clamped_speed * 4 + 50) / 100);
}

fn ledCountClass(led_count: u32) u8 {
    if (led_count <= 32) return 0;
    if (led_count <= 64) return 1;
    return 2;
}

pub fn computeLedCountClasses(shadow: [3]u8, argb_led_counts: [argb_zone_count]u32, resized: [argb_zone_count]bool) [3]u8 {
    var classes = shadow;
    if (resized[0]) classes[0] = (classes[0] & 0xF0) | ledCountClass(argb_led_counts[0]);
    if (resized[1]) classes[0] = (classes[0] & 0x0F) | (ledCountClass(argb_led_counts[1]) << 4);
    if (resized[2]) classes[1] = (classes[1] & 0xF0) | ledCountClass(argb_led_counts[2]);
    return classes;
}

pub fn buildSlotPacket(packet: *[report_length]u8, zone: Zone, effect: HardwareEffect, speed: u32, brightness: u32, color: Rgb) void {
    const zone_spec = spec(zone);
    const bucket = speedBucket(speed);
    const breathing_periods = [_][3]u16{ .{ 500, 500, 250 }, .{ 700, 700, 350 }, .{ 900, 900, 450 }, .{ 1200, 1200, 500 }, .{ 1600, 1600, 800 } };
    const flash_periods = [_][3]u16{ .{ 100, 100, 800 }, .{ 100, 100, 1200 }, .{ 100, 100, 1600 }, .{ 100, 100, 2000 }, .{ 100, 100, 2400 } };
    const cycle_periods = [_][2]u16{ .{ 400, 200 }, .{ 600, 400 }, .{ 550, 450 }, .{ 850, 750 }, .{ 1400, 1200 } };
    buildRequest(packet, zone_spec.slot);
    std.mem.writeInt(u32, packet[2..6], zone_spec.apply_mask, .little);
    const encoded_color = if (effect == .off) Rgb.black else color;
    packet[11] = switch (effect) {
        .off, .static => 1,
        .breathing => 2,
        .flash => 3,
        .cycle => 4,
    };
    packet[12] = brightnessByte(brightness, effect);
    packet[13] = 0;
    packet[14] = encoded_color.b;
    packet[15] = encoded_color.g;
    packet[16] = encoded_color.r;
    switch (effect) {
        .off, .static => {},
        .breathing => {
            std.mem.writeInt(u16, packet[22..24], breathing_periods[bucket][0], .little);
            std.mem.writeInt(u16, packet[24..26], breathing_periods[bucket][1], .little);
            std.mem.writeInt(u16, packet[26..28], breathing_periods[bucket][2], .little);
            packet[30] = 0;
            packet[31] = 1;
            packet[32] = 0;
        },
        .flash => {
            std.mem.writeInt(u16, packet[22..24], flash_periods[bucket][0], .little);
            std.mem.writeInt(u16, packet[24..26], flash_periods[bucket][1], .little);
            std.mem.writeInt(u16, packet[26..28], flash_periods[bucket][2], .little);
            packet[30] = 0;
            packet[31] = 1;
            packet[32] = 1;
        },
        .cycle => {
            std.mem.writeInt(u16, packet[22..24], cycle_periods[bucket][0], .little);
            std.mem.writeInt(u16, packet[24..26], cycle_periods[bucket][1], .little);
            packet[30] = 7;
            packet[31] = 0;
            packet[32] = 0;
        },
    }
}

pub fn buildStreamPacket(packet: *[report_length]u8, command: u8, byte_offset: u16, colors: []const Rgb, order: CalibrationOrder) void {
    buildRequest(packet, command);
    std.mem.writeInt(u16, packet[2..4], byte_offset, .little);
    const byte_count: u8 = @intCast(colors.len * 3);
    packet[4] = byte_count;
    var output_index: usize = 5;
    for (colors) |color| {
        const triplet_bytes = order.triplet(color);
        packet[output_index] = triplet_bytes[0];
        packet[output_index + 1] = triplet_bytes[1];
        packet[output_index + 2] = triplet_bytes[2];
        output_index += 3;
    }
}

fn parseCalibration(bytes: []const u8) ParseError!Calibration {
    if (bytes.len != 4) return error.InvalidLength;
    if (bytes[0] == 0 and bytes[1] == 0 and bytes[2] == 0 and bytes[3] == 0) {
        return .{ .enabled = false, .order = .{ .positions = .{ 0, 1, 2 } } };
    }
    if (bytes[3] != 0) return error.InvalidCalibration;
    var seen: [3]bool = @splat(false);
    var positions: [3]u8 = undefined;
    for (bytes[0..3], 0..) |position, index| {
        if (position > 2 or seen[position]) return error.InvalidCalibration;
        seen[position] = true;
        positions[index] = position;
    }
    return .{ .enabled = true, .order = .{ .positions = positions } };
}

pub fn parseIdentification(info_response: []const u8, extended_response: []const u8) ParseError!Identification {
    if (info_response.len != report_length or extended_response.len != report_length) return error.InvalidLength;
    if (!validReportByte(info_response[0]) or !validReportByte(extended_response[0])) return error.InvalidReport;
    if (info_response[1] != 0x01) return error.InvalidProduct;
    if (extended_response[1] != 0 or extended_response[2] != 0 or extended_response[3] != 0) return error.InvalidExtendedHeader;
    var result = Identification{
        .firmware = @splat(0),
        .firmware_len = 0,
        .firmware_version = info_response[4..8].*,
        .led_count_class_shadow = .{ info_response[8], info_response[9], info_response[10] },
        .feature_flags = info_response[11],
        .calibrations = undefined,
    };
    const firmware_source = info_response[12..40];
    result.firmware_len = std.mem.indexOfScalar(u8, firmware_source, 0) orelse firmware_source.len;
    @memcpy(result.firmware[0..result.firmware_len], firmware_source[0..result.firmware_len]);
    result.calibrations[zoneIndex(.argb1)] = try parseCalibration(info_response[44..48]);
    result.calibrations[zoneIndex(.argb2)] = try parseCalibration(info_response[48..52]);
    result.calibrations[zoneIndex(.argb3)] = try parseCalibration(extended_response[4..8]);
    result.calibrations[zoneIndex(.rgb12v)] = try parseCalibration(info_response[52..56]);
    result.calibrations[zoneIndex(.io_cover)] = try parseCalibration(extended_response[12..16]);
    result.calibrations[zoneIndex(.chipset)] = try parseCalibration(extended_response[16..20]);
    return result;
}

fn validReportByte(byte: u8) bool {
    return byte == report_id or byte == 0;
}

fn expectZeroTail(packet: [report_length]u8, start: usize) !void {
    for (packet[start..]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "calibration order maps RGB colors into the controller triplet" {
    const calibration = (try parseCalibration(&.{ 2, 0, 1, 0 })).order;
    try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x12, 0x56 }, &calibration.triplet(.{ .r = 0x12, .g = 0x34, .b = 0x56 }));
}

test "calibration parser disables all zero words and rejects malformed words" {
    try std.testing.expect(!(try parseCalibration(&.{ 0, 0, 0, 0 })).enabled);
    try std.testing.expectError(error.InvalidCalibration, parseCalibration(&.{ 0, 1, 1, 0 }));
    try std.testing.expectError(error.InvalidCalibration, parseCalibration(&.{ 0, 1, 3, 0 }));
    try std.testing.expectError(error.InvalidCalibration, parseCalibration(&.{ 0, 1, 2, 1 }));
    try std.testing.expectError(error.InvalidLength, parseCalibration(&.{ 0, 1, 2 }));
}

test "identification parser extracts firmware classes flags and all zone calibrations" {
    var info: [report_length]u8 = @splat(0);
    var extended: [report_length]u8 = @splat(0);
    info[0] = report_id;
    info[1] = 1;
    @memcpy(info[4..8], &[_]u8{ 0x04, 0x03, 0x02, 0x01 });
    info[8] = 0x21;
    info[9] = 0x43;
    info[10] = 0x65;
    info[11] = 0x03;
    const grb = [_]u8{ 2, 0, 1, 0 };
    const bgr = [_]u8{ 0, 1, 2, 0 };
    @memcpy(info[12..23], "IT5711 V1.2");
    @memcpy(info[44..48], &grb);
    @memcpy(info[48..52], &grb);
    @memcpy(info[52..56], &bgr);
    extended[0] = 0;
    @memcpy(extended[4..8], &grb);
    @memcpy(extended[12..16], &grb);
    @memcpy(extended[16..20], &grb);
    const identification = try parseIdentification(&info, &extended);
    try std.testing.expectEqualStrings("IT5711 V1.2", identification.firmware[0..identification.firmware_len]);
    try std.testing.expectEqualSlices(u8, &.{ 0x04, 0x03, 0x02, 0x01 }, &identification.firmware_version);
    try std.testing.expectEqualSlices(u8, &.{ 0x21, 0x43, 0x65 }, &identification.led_count_class_shadow);
    try std.testing.expectEqual(@as(u8, 0x03), identification.feature_flags);
    try std.testing.expect(identification.calibrations[zoneIndex(.rgb12v)].enabled);
}

test "identification parser rejects invalid replies" {
    var info: [report_length]u8 = @splat(0);
    var extended: [report_length]u8 = @splat(0);
    info[0] = report_id;
    info[1] = 1;
    extended[0] = report_id;
    const grb = [_]u8{ 2, 0, 1, 0 };
    const bgr = [_]u8{ 0, 1, 2, 0 };
    @memcpy(info[44..48], &grb);
    @memcpy(info[48..52], &grb);
    @memcpy(info[52..56], &bgr);
    @memcpy(extended[4..8], &grb);
    @memcpy(extended[12..16], &grb);
    @memcpy(extended[16..20], &grb);
    try std.testing.expectError(error.InvalidLength, parseIdentification(info[0..63], &extended));
    info[0] = 0xAA;
    try std.testing.expectError(error.InvalidReport, parseIdentification(&info, &extended));
    info[0] = report_id;
    info[1] = 2;
    try std.testing.expectError(error.InvalidProduct, parseIdentification(&info, &extended));
    info[1] = 1;
    extended[2] = 1;
    try std.testing.expectError(error.InvalidExtendedHeader, parseIdentification(&info, &extended));
    extended[2] = 0;
    extended[4] = 3;
    try std.testing.expectError(error.InvalidCalibration, parseIdentification(&info, &extended));
}

test "LED count classes preserve untouched nibbles from the shadow" {
    try std.testing.expectEqual(@as(u8, 0), ledCountClass(0));
    try std.testing.expectEqual(@as(u8, 0), ledCountClass(32));
    try std.testing.expectEqual(@as(u8, 1), ledCountClass(33));
    try std.testing.expectEqual(@as(u8, 1), ledCountClass(64));
    try std.testing.expectEqual(@as(u8, 2), ledCountClass(65));
    try std.testing.expectEqualSlices(u8, &.{ 0x20, 0x52, 0xAB }, &computeLedCountClasses(.{ 0x91, 0x52, 0xAB }, .{ 16, 65, 64 }, .{ true, true, false }));
    try std.testing.expectEqualSlices(u8, &.{ 0x91, 0x51, 0xAB }, &computeLedCountClasses(.{ 0x91, 0x52, 0xAB }, .{ 16, 65, 64 }, .{ false, false, true }));
}

test "simple command packet builders produce exact feature reports" {
    var packet: [report_length]u8 = undefined;
    buildSimpleValue(&packet, command_lamp_array, 0);
    try std.testing.expectEqualSlices(u8, &.{ report_id, command_lamp_array, 0 }, packet[0..3]);
    try expectZeroTail(packet, 3);
    buildApply(&packet, all_zones_mask);
    try std.testing.expectEqualSlices(u8, &.{ report_id, command_apply, 0xFF, 0x07, 0, 0 }, packet[0..6]);
    try expectZeroTail(packet, 6);
    buildDirectMask(&packet, 0x0B);
    try std.testing.expectEqualSlices(u8, &.{ report_id, command_direct_mask, 0x0B }, packet[0..3]);
    try expectZeroTail(packet, 3);
    buildLedCountClasses(&packet, .{ 0x21, 0x03, 0x45 });
    try std.testing.expectEqualSlices(u8, &.{ report_id, command_led_count_class, 0x21, 0x03, 0x45 }, packet[0..5]);
    try expectZeroTail(packet, 5);
}

test "stream packet uses byte offsets byte counts and calibration order" {
    var packet: [report_length]u8 = undefined;
    buildStreamPacket(&packet, 0x58, 6, &.{ .{ .r = 0x12, .g = 0x34, .b = 0x56 }, .{ .r = 0xAA, .g = 0xBB, .b = 0xCC } }, .{ .positions = .{ 2, 0, 1 } });
    try std.testing.expectEqualSlices(u8, &.{ report_id, 0x58, 0x06, 0x00, 0x06, 0x34, 0x12, 0x56, 0xBB, 0xAA, 0xCC }, packet[0..11]);
    try expectZeroTail(packet, 11);
}

test "slot clear covers every zone slot and sends an empty effect with no zones" {
    for (zone_specs) |zone_spec| {
        try std.testing.expect(std.mem.indexOfScalar(u8, &effect_slots, zone_spec.slot) != null);
        try std.testing.expect((all_zones_mask & zone_spec.apply_mask) == zone_spec.apply_mask);
    }
    try std.testing.expectEqualSlices(u8, &.{ 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x90, 0x91, 0x92 }, &effect_slots);
    var packet: [report_length]u8 = @splat(0xAA);
    buildSlotClear(&packet, 0x22);
    try std.testing.expectEqualSlices(u8, &.{ report_id, 0x22 }, packet[0..2]);
    try expectZeroTail(packet, 2);
}

test "slot packet for off at speeds 0 50 100 ignores color and uses static black" {
    for ([_]u32{ 0, 50, 100 }) |speed| {
        var packet: [report_length]u8 = undefined;
        buildSlotPacket(&packet, .argb1, .off, speed, 77, .{ .r = 0x12, .g = 0x34, .b = 0x56 });
        try std.testing.expectEqualSlices(u8, &.{ report_id, 0x25, 0x20, 0, 0, 0 }, packet[0..6]);
        try std.testing.expectEqual(@as(u8, 1), packet[11]);
        try std.testing.expectEqual(@as(u8, 196), packet[12]);
        try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, packet[14..17]);
        try expectZeroTail(packet, 17);
    }
}

test "slot packet for static at speeds 0 50 100 keeps the hand computed static bytes" {
    for ([_]u32{ 0, 50, 100 }) |speed| {
        var packet: [report_length]u8 = undefined;
        buildSlotPacket(&packet, .argb1, .static, speed, 100, .{ .r = 0x12, .g = 0x34, .b = 0x56 });
        try std.testing.expectEqualSlices(u8, &.{ report_id, 0x25, 0x20, 0, 0, 0 }, packet[0..6]);
        try std.testing.expectEqual(@as(u8, 1), packet[11]);
        try std.testing.expectEqual(@as(u8, 0xFF), packet[12]);
        try std.testing.expectEqualSlices(u8, &.{ 0x56, 0x34, 0x12 }, packet[14..17]);
        try expectZeroTail(packet, 17);
    }
}

test "slot packet for breathing at speeds 0 50 100 uses the hand computed buckets" {
    const expected = [_][8]u8{
        .{ 0x40, 0x06, 0x40, 0x06, 0x20, 0x03, 0, 0 },
        .{ 0x84, 0x03, 0x84, 0x03, 0xC2, 0x01, 0, 0 },
        .{ 0xF4, 0x01, 0xF4, 0x01, 0xFA, 0x00, 0, 0 },
    };
    for ([_]u32{ 0, 50, 100 }, 0..) |speed, index| {
        var packet: [report_length]u8 = undefined;
        buildSlotPacket(&packet, .argb1, .breathing, speed, 100, .{ .r = 0x12, .g = 0x34, .b = 0x56 });
        try std.testing.expectEqual(@as(u8, 2), packet[11]);
        try std.testing.expectEqual(@as(u8, 0x64), packet[12]);
        try std.testing.expectEqualSlices(u8, expected[index][0..6], packet[22..28]);
        try std.testing.expectEqualSlices(u8, &.{ 0, 1, 0 }, packet[30..33]);
    }
}

test "slot packet for flash at speeds 0 50 100 uses the hand computed buckets" {
    const expected = [_][6]u8{
        .{ 0x64, 0, 0x64, 0, 0x60, 0x09 },
        .{ 0x64, 0, 0x64, 0, 0x40, 0x06 },
        .{ 0x64, 0, 0x64, 0, 0x20, 0x03 },
    };
    for ([_]u32{ 0, 50, 100 }, 0..) |speed, index| {
        var packet: [report_length]u8 = undefined;
        buildSlotPacket(&packet, .argb1, .flash, speed, 100, .{ .r = 0x12, .g = 0x34, .b = 0x56 });
        try std.testing.expectEqual(@as(u8, 3), packet[11]);
        try std.testing.expectEqualSlices(u8, expected[index][0..6], packet[22..28]);
        try std.testing.expectEqualSlices(u8, &.{ 0, 1, 1 }, packet[30..33]);
    }
}

test "slot packet for cycle at speeds 0 50 100 uses the hand computed buckets" {
    const expected = [_][4]u8{
        .{ 0x78, 0x05, 0xB0, 0x04 },
        .{ 0x26, 0x02, 0xC2, 0x01 },
        .{ 0x90, 0x01, 0xC8, 0x00 },
    };
    for ([_]u32{ 0, 50, 100 }, 0..) |speed, index| {
        var packet: [report_length]u8 = undefined;
        buildSlotPacket(&packet, .argb1, .cycle, speed, 100, .{ .r = 0x12, .g = 0x34, .b = 0x56 });
        try std.testing.expectEqual(@as(u8, 4), packet[11]);
        try std.testing.expectEqualSlices(u8, expected[index][0..4], packet[22..26]);
        try std.testing.expectEqualSlices(u8, &.{ 7, 0, 0 }, packet[30..33]);
    }
}
