const std = @import("std");

pub const control_temperature_register: u32 = 0x00059800;
pub const ccd_temperature_base_register: u32 = 0x00059B08;
pub const ccd_temperature_count: usize = 8;
pub const rapl_unit_msr: u64 = 0xC0010299;
pub const rapl_energy_status_msr: u64 = 0xC001029B;

const PowerComputation = struct {
    next_counter: u32,
    next_ticks: i64,
    power_watts: ?f64,
};

pub fn decodeControlTemperature(raw: u32) f64 {
    const encoded = (raw >> 21) & 0x7FF;
    var temperature = @as(f64, @floatFromInt(encoded)) * 0.125;
    if (((raw >> 19) & 1) != 0 or ((raw >> 16) & 3) == 3) temperature -= 49.0;
    return temperature;
}

pub fn decodeCcdTemperature(raw: u32) ?f64 {
    if (raw == 0xFFFFFFFF) return null;
    if (((raw >> 11) & 1) == 0) return null;
    const encoded = raw & 0x7FF;
    return @as(f64, @floatFromInt(encoded)) * 0.125 - 49.0;
}

pub fn energyUnitJoules(msr_value: u64) f64 {
    const exponent: u6 = @intCast((msr_value >> 8) & 0x1F);
    var unit: f64 = 1.0;
    for (0..exponent) |_| unit *= 0.5;
    return unit;
}

pub fn computePower(previous_counter: ?u32, previous_ticks: ?i64, current_counter: u32, current_ticks: i64, frequency: i64, unit_joules: f64) PowerComputation {
    const prior_counter = previous_counter orelse return .{ .next_counter = current_counter, .next_ticks = current_ticks, .power_watts = null };
    const prior_ticks = previous_ticks orelse return .{ .next_counter = current_counter, .next_ticks = current_ticks, .power_watts = null };
    const elapsed_ticks = current_ticks - prior_ticks;
    if (elapsed_ticks <= 0 or frequency <= 0 or !(unit_joules == unit_joules)) return .{ .next_counter = current_counter, .next_ticks = current_ticks, .power_watts = null };
    const delta = current_counter -% prior_counter;
    const seconds = @as(f64, @floatFromInt(elapsed_ticks)) / @as(f64, @floatFromInt(frequency));
    const joules = @as(f64, @floatFromInt(delta)) * unit_joules;
    return .{ .next_counter = current_counter, .next_ticks = current_ticks, .power_watts = joules / seconds };
}

pub fn normalizeTemperature(temperature: f64) ?f64 {
    if (!(temperature == temperature)) return null;
    if (temperature < -50.0) return -50.0;
    if (temperature > 150.0) return 150.0;
    return temperature;
}

pub fn normalizePower(power_watts: f64) ?f64 {
    if (!(power_watts == power_watts)) return null;
    if (power_watts < 0.0) return 0.0;
    if (power_watts > 1000.0) return 1000.0;
    return power_watts;
}

test "control temperature decodes bit nineteen offset" {
    const raw = (@as(u32, 480) << 21) | (@as(u32, 1) << 19);
    try std.testing.expectEqual(@as(f64, 11.0), decodeControlTemperature(raw));
}

test "control temperature decodes tj select offset" {
    const raw = (@as(u32, 800) << 21) | (@as(u32, 3) << 16);
    try std.testing.expectEqual(@as(f64, 51.0), decodeControlTemperature(raw));
}

test "ccd temperature rejects values without the valid bit" {
    try std.testing.expectEqual(@as(?f64, null), decodeCcdTemperature(872));
}

test "ccd temperature rejects all one bits" {
    try std.testing.expectEqual(@as(?f64, null), decodeCcdTemperature(0xFFFFFFFF));
}

test "ccd temperature decodes a valid reading" {
    try std.testing.expectEqual(@as(?f64, 60.0), decodeCcdTemperature((@as(u32, 1) << 11) | 872));
}

test "energy unit uses repeated halving from the encoded exponent" {
    try std.testing.expectEqual(@as(f64, 1.0 / 65536.0), energyUnitJoules(@as(u64, 16) << 8));
}

test "power computation treats the first sample as a baseline" {
    const result = computePower(null, null, 1234, 1000, 1000, 0.25);
    try std.testing.expectEqual(@as(u32, 1234), result.next_counter);
    try std.testing.expectEqual(@as(i64, 1000), result.next_ticks);
    try std.testing.expectEqual(@as(?f64, null), result.power_watts);
}

test "power computation handles a wrapping energy counter" {
    const result = computePower(0xFFFFFFF0, 1000, 0x00000010, 3000, 1000, 0.25);
    try std.testing.expectEqual(@as(?f64, 4.0), result.power_watts);
}

test "normalizers clamp finite out of range values and reject nan" {
    try std.testing.expectEqual(@as(?f64, -50.0), normalizeTemperature(-60.0));
    try std.testing.expectEqual(@as(?f64, 150.0), normalizeTemperature(160.0));
    try std.testing.expectEqual(@as(?f64, 0.0), normalizePower(-1.0));
    try std.testing.expectEqual(@as(?f64, 1000.0), normalizePower(1200.0));
    const nan_value = std.math.nan(f64);
    try std.testing.expectEqual(@as(?f64, null), normalizeTemperature(nan_value));
    try std.testing.expectEqual(@as(?f64, null), normalizePower(nan_value));
}
