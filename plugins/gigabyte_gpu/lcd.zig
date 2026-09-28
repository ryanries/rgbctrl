const std = @import("std");
const text = @import("sdk").text;

// Legacy Gigabyte LCD protocol at 7-bit address 0x61, as documented by the open-source drivers
// for the RTX 5080 AORUS MASTER ICE (firmware F1.4) and the RTX 5090 MASTER.
pub const address: u7 = 0x61;
pub const frame_length = 256;
pub const reply_length = 4;
const magic = [4]u8{ 0xCB, 0x55, 0xAC, 0x38 };

const opcode_read_firmware: u8 = 0xD6;
const opcode_read_mode: u8 = 0xDE;
const opcode_open: u8 = 0xE7;
const opcode_set_mode: u8 = 0xE5;
const opcode_set_overlay: u8 = 0xE1;
const opcode_set_values: u8 = 0xE3;

pub const default_seconds: u8 = 4;
pub const refresh_after_ms: u64 = 30_000;
pub const stale_after_ms: u64 = 5000;
pub const hold_ms: u64 = 10_000;

/// Cards whose LCD has been tested with this protocol: the RTX 5080 AORUS MASTER ICE.
pub fn supports(device_id: u16, subvendor_id: u16, subdevice_id: u16) bool {
    return device_id == 0x2C02 and subvendor_id == 0x1458 and subdevice_id == 0x418C;
}

pub const Mode = enum(u8) { faith1 = 0, faith2 = 1, faith3 = 2, image = 3, text = 4, gif = 5, chibi = 6, carousel = 7 };

fn modeArgument(mode: Mode) u8 {
    return if (mode == .carousel) 10 else @intFromEnum(mode) + 1;
}

/// Overlay fields in the order of the E1 flags and the E3 values; `fps` has no host source.
pub const Metric = enum(u3) { temp, clock, load, fan, vram_clock, vram, fps, power };

pub const metric_sensors = [_][]const u8{ "gpu.temp", "gpu.freq", "gpu.load", "gpu.fan", "gpu.mem.freq", "gpu.mem.load", "", "gpu.power" };

pub fn bit(metric: Metric) u8 {
    return @as(u8, 1) << @intFromEnum(metric);
}

pub const default_metrics: u8 = bit(.temp) | bit(.load) | bit(.fan) | bit(.power);

const metric_names = [_][]const u8{ "temp", "clock", "load", "fan", "vram_clock", "vram", "fps", "power" };

pub fn parseMetric(name: []const u8) ?Metric {
    for (metric_names, 0..) |metric_name, index| {
        const metric: Metric = @enumFromInt(index);
        if (metric != .fps and std.mem.eql(u8, metric_name, name)) return metric;
    }
    return null;
}

pub fn describe(buffer: []u8, flags: u8) []const u8 {
    var length: usize = 0;
    for (metric_names, 0..) |name, index| {
        if ((flags >> @intCast(index)) & 1 == 0) continue;
        const separator: []const u8 = if (length == 0) "" else ", ";
        if (length + separator.len + name.len > buffer.len) break;
        @memcpy(buffer[length..][0..separator.len], separator);
        length += separator.len;
        @memcpy(buffer[length..][0..name.len], name);
        length += name.len;
    }
    return buffer[0..length];
}

fn begin(frame: *[frame_length]u8, opcode: u8) void {
    @memset(frame, 0);
    frame[0] = opcode;
    @memcpy(frame[1..5], &magic);
}

pub fn buildReadFirmware(frame: *[frame_length]u8) void {
    begin(frame, opcode_read_firmware);
}

pub fn buildReadMode(frame: *[frame_length]u8) void {
    begin(frame, opcode_read_mode);
}

pub fn buildOpen(frame: *[frame_length]u8, on: bool) void {
    begin(frame, opcode_open);
    frame[5] = if (on) 1 else 2;
}

pub fn buildSetMode(frame: *[frame_length]u8, mode: Mode) void {
    begin(frame, opcode_set_mode);
    frame[5] = modeArgument(mode);
}

/// Zero flags clear the overlay.
pub fn buildOverlay(frame: *[frame_length]u8, flags: u8, seconds: u8) void {
    begin(frame, opcode_set_overlay);
    for (0..8) |index| frame[5 + index] = @intFromBool((flags >> @intCast(index)) & 1 != 0);
    frame[13] = seconds;
}

pub const Encoded = struct {
    temp: u8 = 0,
    clock: u16 = 0,
    load: u8 = 0,
    fan: u16 = 0,
    vram_clock: u16 = 0,
    vram: u8 = 0,
    power: u16 = 0,
};

pub fn buildValues(frame: *[frame_length]u8, values: Encoded) void {
    begin(frame, opcode_set_values);
    frame[5] = values.temp;
    std.mem.writeInt(u16, frame[6..8], values.clock, .big);
    frame[8] = values.load;
    std.mem.writeInt(u16, frame[9..11], values.fan, .big);
    std.mem.writeInt(u16, frame[11..13], values.vram_clock, .big);
    frame[13] = values.vram;
    std.mem.writeInt(u16, frame[16..18], values.power, .big);
}

pub fn parseFirmware(reply: []const u8) ?u8 {
    if (reply.len < 2 or reply[0] != opcode_read_firmware) return null;
    return reply[1];
}

pub const PanelState = struct { mode: Mode, on: bool };

/// DE: byte 1 is the screen plus one (10 for the carousel) and byte 2 is 1 while the panel is on.
/// A zero or unknown screen byte, which bus contention can produce, reads as null.
pub fn parseState(reply: []const u8) ?PanelState {
    if (reply.len < 3) return null;
    const mode: Mode = switch (reply[1]) {
        1...7 => @enumFromInt(reply[1] - 1),
        10 => .carousel,
        else => return null,
    };
    return .{ .mode = mode, .on = reply[2] == 1 };
}

/// `readings` holds one value per metric in Metric order; disabled metrics are sent as 0.
pub fn encode(flags: u8, readings: [8]f64) Encoded {
    const Reading = struct {
        fn at(values: [8]f64, enabled: u8, metric: Metric) f64 {
            return if (enabled & bit(metric) != 0) values[@intFromEnum(metric)] else 0;
        }
    };
    return .{
        .temp = text.roundToInt(u8, Reading.at(readings, flags, .temp)),
        .clock = text.roundToInt(u16, Reading.at(readings, flags, .clock)),
        .load = text.roundToInt(u8, @min(Reading.at(readings, flags, .load), 100)),
        .fan = text.roundToInt(u16, Reading.at(readings, flags, .fan)),
        .vram_clock = text.roundToInt(u16, Reading.at(readings, flags, .vram_clock)),
        .vram = text.roundToInt(u8, @min(Reading.at(readings, flags, .vram), 100)),
        .power = text.roundToInt(u16, Reading.at(readings, flags, .power)),
    };
}

fn moved(comptime T: type, previous: T, next: T, threshold: T) bool {
    const difference = if (next > previous) next - previous else previous - next;
    return difference >= threshold;
}

/// Each E3 write stalls the GPU briefly, so small changes of the shown values are skipped.
pub fn worthSending(flags: u8, previous: Encoded, next: Encoded) bool {
    if (flags & bit(.temp) != 0 and moved(u8, previous.temp, next.temp, 1)) return true;
    if (flags & bit(.clock) != 0 and moved(u16, previous.clock, next.clock, 15)) return true;
    if (flags & bit(.load) != 0 and moved(u8, previous.load, next.load, 2)) return true;
    if (flags & bit(.fan) != 0 and moved(u16, previous.fan, next.fan, 50)) return true;
    if (flags & bit(.vram_clock) != 0 and moved(u16, previous.vram_clock, next.vram_clock, 15)) return true;
    if (flags & bit(.vram) != 0 and moved(u8, previous.vram, next.vram, 1)) return true;
    if (flags & bit(.power) != 0 and moved(u16, previous.power, next.power, 3)) return true;
    return false;
}

pub const SensorHold = struct {
    last_value: f64 = 0,
    // The last good reading, or the first query of a sensor not seen yet, which gets the same
    // grace while its source is still starting.
    hold_from_ms: ?u64 = null,
    seen: bool = false,
    warned: bool = false,

    pub const Reading = struct {
        value: f64,
        age_ms: u64,
    };

    pub const Resolution = struct {
        value: f64,
        pending: bool = false,
        became_unavailable: bool = false,
    };

    /// A stale sensor keeps its last value for 10 s and one not seen yet is pending for 10 s;
    /// after that both read 0 and are reported once.
    pub fn resolve(self: *SensorHold, reading: ?Reading, now_ms: u64) Resolution {
        if (reading) |sensor| {
            if (sensor.age_ms <= stale_after_ms) {
                self.last_value = sensor.value;
                self.hold_from_ms = now_ms -| sensor.age_ms;
                self.seen = true;
                self.warned = false;
                return .{ .value = sensor.value };
            }
        }
        const from = self.hold_from_ms orelse now_ms;
        self.hold_from_ms = from;
        if (now_ms -| from <= hold_ms) return .{ .value = self.last_value, .pending = !self.seen };
        const first = !self.warned;
        self.warned = true;
        return .{ .value = 0, .became_unavailable = first };
    }

    /// Starts the grace again after a gap in the queries, such as sleep, that aged every
    /// reading; a sensor already reported missing stays at 0 until it delivers again.
    pub fn restart(self: *SensorHold, now_ms: u64) void {
        if (!self.warned) self.hold_from_ms = now_ms;
    }
};

fn expectZeroTail(frame: [frame_length]u8, start: usize) !void {
    for (frame[start..]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "commands are 256-byte frames with the opcode, the magic and zero padding" {
    var frame = [_]u8{0xAA} ** frame_length;
    buildReadFirmware(&frame);
    try std.testing.expectEqualSlices(u8, &.{ 0xD6, 0xCB, 0x55, 0xAC, 0x38 }, frame[0..5]);
    try expectZeroTail(frame, 5);
    buildReadMode(&frame);
    try std.testing.expectEqualSlices(u8, &.{ 0xDE, 0xCB, 0x55, 0xAC, 0x38 }, frame[0..5]);
    try expectZeroTail(frame, 5);
    buildOpen(&frame, true);
    try std.testing.expectEqualSlices(u8, &.{ 0xE7, 0xCB, 0x55, 0xAC, 0x38, 0x01 }, frame[0..6]);
    try expectZeroTail(frame, 6);
    buildOpen(&frame, false);
    try std.testing.expectEqualSlices(u8, &.{ 0xE7, 0xCB, 0x55, 0xAC, 0x38, 0x02 }, frame[0..6]);
    try expectZeroTail(frame, 6);
}

test "set mode sends mode plus one and ten for the carousel" {
    var frame: [frame_length]u8 = undefined;
    buildSetMode(&frame, .faith1);
    try std.testing.expectEqualSlices(u8, &.{ 0xE5, 0xCB, 0x55, 0xAC, 0x38, 0x01 }, frame[0..6]);
    try expectZeroTail(frame, 6);
    buildSetMode(&frame, .faith3);
    try std.testing.expectEqual(@as(u8, 3), frame[5]);
    buildSetMode(&frame, .carousel);
    try std.testing.expectEqual(@as(u8, 10), frame[5]);
}

test "overlay frame has one byte per metric then the rotation interval" {
    var frame: [frame_length]u8 = undefined;
    buildOverlay(&frame, default_metrics, 4);
    try std.testing.expectEqualSlices(u8, &.{ 0xE1, 0xCB, 0x55, 0xAC, 0x38, 1, 0, 1, 1, 0, 0, 0, 1, 4 }, frame[0..14]);
    try expectZeroTail(frame, 14);
    buildOverlay(&frame, 0, 0);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 9), frame[5..14]);
}

test "values frame packs 16-bit fields big-endian and leaves fps at zero" {
    var frame: [frame_length]u8 = undefined;
    buildValues(&frame, .{ .temp = 61, .clock = 2805, .load = 97, .fan = 1650, .vram_clock = 15001, .vram = 42, .power = 318 });
    try std.testing.expectEqualSlices(u8, &.{ 0xE3, 0xCB, 0x55, 0xAC, 0x38, 61, 0x0A, 0xF5, 97, 0x06, 0x72, 0x3A, 0x99, 42, 0, 0, 0x01, 0x3E }, frame[0..18]);
    try expectZeroTail(frame, 18);
}

test "replies decode the firmware version, the display mode and the panel power" {
    try std.testing.expectEqual(@as(?u8, 0x14), parseFirmware(&.{ 0xD6, 0x14, 0x01, 0x02 }));
    try std.testing.expectEqual(@as(?u8, null), parseFirmware(&.{ 0x00, 0x14, 0x01, 0x02 }));
    try std.testing.expectEqual(@as(?PanelState, .{ .mode = .faith1, .on = true }), parseState(&.{ 0xDE, 1, 1, 0 }));
    try std.testing.expectEqual(@as(?PanelState, .{ .mode = .chibi, .on = false }), parseState(&.{ 0xDE, 7, 2, 0 }));
    try std.testing.expectEqual(@as(?PanelState, .{ .mode = .carousel, .on = true }), parseState(&.{ 0xDE, 10, 1, 0 }));
    try std.testing.expectEqual(@as(?PanelState, null), parseState(&.{ 0xDE, 0, 1, 0 }));
    try std.testing.expectEqual(@as(?PanelState, null), parseState(&.{ 0xDE, 9, 1, 0 }));
    try std.testing.expectEqual(@as(?PanelState, null), parseState(&.{ 0xD6, 0x14, 0x01, 0x02 }));
    try std.testing.expectEqual(@as(?PanelState, null), parseState(&.{ 0xDE, 1 }));
}

test "metric names map to overlay flags and only the supported cards match" {
    try std.testing.expectEqual(@as(u8, 0x8D), default_metrics);
    try std.testing.expectEqual(@as(?Metric, .vram_clock), parseMetric("vram_clock"));
    try std.testing.expectEqual(@as(?Metric, null), parseMetric("fps"));
    try std.testing.expectEqualStrings("gpu.fan", metric_sensors[@intFromEnum(Metric.fan)]);
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("temp, load, fan, power", describe(&buffer, default_metrics));
    try std.testing.expectEqualStrings("temp", describe(buffer[0..8], default_metrics));
    try std.testing.expect(supports(0x2C02, 0x1458, 0x418C));
    try std.testing.expect(!supports(0x2B85, 0x1458, 0x416E));
}

test "encode rounds and clamps readings and zeroes the metrics that are off" {
    const readings = [8]f64{ 60.6, 2804.6, 101, -5, 15001.2, 42.4, 99, 70000 };
    const all = encode(0xFF, readings);
    try std.testing.expectEqual(Encoded{ .temp = 61, .clock = 2805, .load = 100, .fan = 0, .vram_clock = 15001, .vram = 42, .power = 65535 }, all);
    const some = encode(bit(.temp) | bit(.power), readings);
    try std.testing.expectEqual(Encoded{ .temp = 61, .power = 65535 }, some);
}

test "only changes of shown metrics above the display noise are worth a write" {
    const flags = default_metrics;
    const base = Encoded{ .temp = 60, .clock = 2800, .load = 50, .fan = 1500, .power = 300 };
    try std.testing.expect(!worthSending(flags, base, base));
    try std.testing.expect(worthSending(flags, base, .{ .temp = 61, .clock = 2800, .load = 50, .fan = 1500, .power = 300 }));
    try std.testing.expect(!worthSending(flags, base, .{ .temp = 60, .clock = 2800, .load = 51, .fan = 1549, .power = 302 }));
    try std.testing.expect(worthSending(flags, base, .{ .temp = 60, .clock = 2800, .load = 50, .fan = 1450, .power = 300 }));
    try std.testing.expect(!worthSending(flags, base, .{ .temp = 60, .clock = 1000, .load = 50, .fan = 1500, .power = 300 }));
}

test "a stale sensor holds its last value for ten seconds and then reads zero once reported" {
    var hold = SensorHold{};
    try std.testing.expectEqual(@as(f64, 61), hold.resolve(.{ .value = 61, .age_ms = 100 }, 1000).value);
    const held = hold.resolve(.{ .value = 99, .age_ms = 6000 }, 5000);
    try std.testing.expectEqual(@as(f64, 61), held.value);
    try std.testing.expect(!held.became_unavailable);
    const expired = hold.resolve(null, 20000);
    try std.testing.expectEqual(@as(f64, 0), expired.value);
    try std.testing.expect(expired.became_unavailable);
    try std.testing.expect(!hold.resolve(null, 21000).became_unavailable);
}

test "a sensor not seen yet is pending for ten seconds before it reads zero once reported" {
    var hold = SensorHold{};
    const starting = hold.resolve(null, 1000);
    try std.testing.expect(starting.pending);
    try std.testing.expect(!starting.became_unavailable);
    try std.testing.expectEqual(@as(f64, 0), starting.value);
    try std.testing.expect(hold.resolve(.{ .value = 50, .age_ms = 9000 }, 11000).pending);
    const missing = hold.resolve(null, 11001);
    try std.testing.expect(!missing.pending);
    try std.testing.expect(missing.became_unavailable);
    const arrived = hold.resolve(.{ .value = 55, .age_ms = 200 }, 12000);
    try std.testing.expect(!arrived.pending);
    try std.testing.expectEqual(@as(f64, 55), arrived.value);
}

test "after a long gap such as sleep the grace starts again, but a missing sensor stays missing" {
    var hold = SensorHold{};
    _ = hold.resolve(.{ .value = 61, .age_ms = 100 }, 1000);
    hold.restart(8 * 3600 * 1000);
    const resumed = hold.resolve(.{ .value = 61, .age_ms = 8 * 3600 * 1000 }, 8 * 3600 * 1000);
    try std.testing.expectEqual(@as(f64, 61), resumed.value);
    try std.testing.expect(!resumed.pending);
    try std.testing.expect(!resumed.became_unavailable);
    var missing = SensorHold{};
    _ = missing.resolve(null, 0);
    try std.testing.expect(missing.resolve(null, 20000).became_unavailable);
    missing.restart(100000);
    const still = missing.resolve(null, 100000);
    try std.testing.expectEqual(@as(f64, 0), still.value);
    try std.testing.expect(!still.became_unavailable);
}
