const std = @import("std");

pub const vendor_id: u16 = 0x381C;
pub const product_id: u16 = 0x0003;
const report_id: u8 = 0x10;
pub const report_length = 64;
const frame_start: u8 = 0x68;
const frame_address: u8 = 0x01;
const device_byte: u8 = 0x09;
const data_length: u8 = 0x0D;
const opcode_display: u8 = 0x01;
const frame_end: u8 = 0x16;
pub const default_power_bar_max_watts: u16 = 162;

pub const Mode = enum(u8) {
    close = 0,
    open = 1,
    display = 2,
};

pub const Unit = enum(u8) {
    celsius = 0,
    fahrenheit = 1,
};

const Reading = struct {
    power_w: u16,
    power_bar: u8,
    unit: Unit,
    temperature: f32,
    load: u8,
    frequency_mhz: u16,
};

pub const placeholder = Reading{
    .power_w = 100,
    .power_bar = 50,
    .unit = .celsius,
    .temperature = 60.0,
    .load = 40,
    .frequency_mhz = 3600,
};

pub fn buildFrame(frame: *[report_length]u8, mode: Mode, reading: Reading) void {
    @memset(frame, 0);
    frame[0] = report_id;
    frame[1] = frame_start;
    frame[2] = frame_address;
    frame[3] = device_byte;
    frame[4] = data_length;
    frame[5] = opcode_display;
    frame[6] = @intFromEnum(mode);
    std.mem.writeInt(u16, frame[7..9], reading.power_w, .big);
    frame[9] = reading.power_bar;
    frame[10] = @intFromEnum(reading.unit);
    std.mem.writeInt(u32, frame[11..15], @bitCast(reading.temperature), .big);
    frame[15] = reading.load;
    std.mem.writeInt(u16, frame[16..18], reading.frequency_mhz, .big);
    frame[18] = checksum(frame[1..18]);
    frame[19] = frame_end;
}

fn checksum(bytes: []const u8) u8 {
    var sum: u8 = 0;
    for (bytes) |byte| sum +%= byte;
    return sum;
}

fn powerBar(power_w: u16, max_watts: u16) u8 {
    if (max_watts == 0) return 0;
    const bar = (@as(u32, power_w) * 100 + max_watts / 2) / max_watts;
    return @intCast(@min(bar, 100));
}

fn celsiusToFahrenheit(celsius: f64) f64 {
    return celsius * 9.0 / 5.0 + 32.0;
}

fn clampRound(comptime T: type, value: f64) T {
    if (!(value == value) or value <= 0) return 0;
    const max: f64 = @floatFromInt(std.math.maxInt(T));
    if (value >= max) return std.math.maxInt(T);
    return @intFromFloat(value + 0.5);
}

const Inputs = struct {
    temperature_c: f64,
    power_w: f64,
    load_percent: f64,
    frequency_mhz: f64,
};

pub fn toReading(inputs: Inputs, unit: Unit, power_bar_max_watts: u16) Reading {
    const power = clampRound(u16, inputs.power_w);
    const temperature = switch (unit) {
        .celsius => inputs.temperature_c,
        .fahrenheit => celsiusToFahrenheit(inputs.temperature_c),
    };
    return .{
        .power_w = power,
        .power_bar = powerBar(power, power_bar_max_watts),
        .unit = unit,
        .temperature = @floatCast(temperature),
        .load = @min(clampRound(u8, inputs.load_percent), 100),
        .frequency_mhz = clampRound(u16, inputs.frequency_mhz),
    };
}

fn expectFrame(expected: []const u8, mode: Mode, reading: Reading) !void {
    var frame: [report_length]u8 = undefined;
    buildFrame(&frame, mode, reading);
    try std.testing.expectEqualSlices(u8, expected, frame[0..expected.len]);
    for (frame[expected.len..]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "display frame reproduces the published worked example byte for byte" {
    try expectFrame(
        &.{ 0x10, 0x68, 0x01, 0x09, 0x0D, 0x01, 0x02, 0x00, 0x58, 0x26, 0x00, 0x42, 0x82, 0x00, 0x00, 0x17, 0x12, 0xF2, 0xDF, 0x16 },
        .display,
        .{ .power_w = 88, .power_bar = 38, .unit = .celsius, .temperature = 65.0, .load = 23, .frequency_mhz = 4850 },
    );
}

test "open frame matches the vendor application's hard-coded frame" {
    try expectFrame(
        &.{ 0x10, 0x68, 0x01, 0x09, 0x0D, 0x01, 0x01, 0x00, 0x64, 0x32, 0x00, 0x42, 0x70, 0x00, 0x00, 0x28, 0x0E, 0x10, 0x0F, 0x16 },
        .open,
        placeholder,
    );
}

test "close frame differs from the open frame only in the mode byte and checksum" {
    var frame: [report_length]u8 = undefined;
    buildFrame(&frame, .close, placeholder);
    try std.testing.expectEqual(@as(u8, 0x00), frame[6]);
    try std.testing.expectEqual(@as(u8, 0x0E), frame[18]);
}

test "power bar scales against the configured maximum and clamps at 100" {
    try std.testing.expectEqual(@as(u8, 50), powerBar(100, 200));
    try std.testing.expectEqual(@as(u8, 100), powerBar(400, 200));
    try std.testing.expectEqual(@as(u8, 0), powerBar(0, 162));
    try std.testing.expectEqual(@as(u8, 0), powerBar(50, 0));
    try std.testing.expectEqual(@as(u8, 54), powerBar(88, 162));
}

test "toReading converts to Fahrenheit before encoding and clamps inputs" {
    const reading = toReading(.{ .temperature_c = 100.0, .power_w = -3.0, .load_percent = 140.0, .frequency_mhz = 4850.4 }, .fahrenheit, 162);
    try std.testing.expectEqual(@as(f32, 212.0), reading.temperature);
    try std.testing.expectEqual(Unit.fahrenheit, reading.unit);
    try std.testing.expectEqual(@as(u16, 0), reading.power_w);
    try std.testing.expectEqual(@as(u8, 100), reading.load);
    try std.testing.expectEqual(@as(u16, 4850), reading.frequency_mhz);
}
