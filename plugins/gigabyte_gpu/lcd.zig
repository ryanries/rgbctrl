const std = @import("std");
const sdk = @import("sdk");
const text = sdk.text;
const Rgb = sdk.abi.Rgb;

// The RTX 5080 AORUS MASTER ICE ships with either of two LCD controllers under the same PCI
// identity, both driven with 256-byte zero-padded frames on the card's I2C bus:
// - legacy, at 0x61: `<opcode> CB 55 AC 38 <arguments>`, as documented by the open-source
//   drivers for that card (firmware F1.4) and the RTX 5090 MASTER;
// - ex ("LcdEx" in Gigabyte's software), at 0x76: `<opcode> 01 <arguments>`, as Gigabyte
//   Control Center 26.09 and its AorusLcdService drive it.
pub const Kind = enum { legacy, ex };

pub const address: u7 = 0x61;
pub const ex_address: u7 = 0x76;
pub const frame_length = 256;
pub const reply_length = 4;
const magic = [4]u8{ 0xCB, 0x55, 0xAC, 0x38 };

const opcode_read_firmware: u8 = 0xD6;
const opcode_read_mode: u8 = 0xDE;
const opcode_open: u8 = 0xE7;
const opcode_set_mode: u8 = 0xE5;
const opcode_set_overlay: u8 = 0xE1;
const opcode_set_values: u8 = 0xE3;

const ex_opcode_read_firmware: u8 = 0x10;
const ex_opcode_set_area: u8 = 0x12;
const ex_opcode_open: u8 = 0x15;
const ex_opcode_set_mode: u8 = 0x16;
const ex_opcode_set_overlay: u8 = 0x17;
const ex_opcode_set_values: u8 = 0x23;

// An effect for one color area of the newer panel ("LedSet" in Gigabyte's software): style 1 is
// static (2 cycle, 3 gradient, 4 wave), and speed 6 and brightness 10 are the tops of its
// lighting page's sliders, where they start.
const ex_area_static: u8 = 1;
const ex_area_speed: u8 = 6;
const ex_area_brightness: u8 = 10;
/// Gigabyte's software waits this long after each color area it sets.
pub const ex_area_pause_ms: u32 = 120;

pub const default_seconds: u8 = 4;
/// Gigabyte's software offers 1 to 10 s per overlay field on the newer panel.
pub const ex_max_seconds: u8 = 10;
pub const default_color = Rgb{ .r = 0xFF, .g = 0xFF, .b = 0xFF };
pub const refresh_after_ms: u64 = 30_000;
pub const stale_after_ms: u64 = 5000;
pub const hold_ms: u64 = 10_000;

/// Cards whose LCD rgbctrl drives: the RTX 5080 AORUS MASTER ICE, with either controller.
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

fn beginEx(frame: *[frame_length]u8, opcode: u8) void {
    @memset(frame, 0);
    frame[0] = opcode;
    frame[1] = 0x01;
}

/// The version query Gigabyte's software sends to `ex_address` before it falls back to `address`.
pub fn buildExReadFirmware(frame: *[frame_length]u8) void {
    beginEx(frame, ex_opcode_read_firmware);
}

pub fn buildExOpen(frame: *[frame_length]u8, on: bool) void {
    beginEx(frame, ex_opcode_open);
    frame[2] = if (on) 1 else 2;
}

/// Unlike the legacy E5, the screen number goes out as is (7 for the carousel).
pub fn buildExSetMode(frame: *[frame_length]u8, mode: Mode) void {
    beginEx(frame, ex_opcode_set_mode);
    frame[2] = @intFromEnum(mode);
}

/// The overlay switch alone. Gigabyte's software sends it before every overlay setup, and it
/// alone switches the overlay off.
pub fn buildExOverlaySwitch(frame: *[frame_length]u8, on: bool) void {
    beginEx(frame, ex_opcode_set_overlay);
    frame[2] = @intFromBool(on);
}

/// The overlay: one flag bit per field in Metric order, the seconds each field stays up and
/// the text color.
pub fn buildExOverlay(frame: *[frame_length]u8, flags: u8, seconds: u8, color: Rgb) void {
    buildExOverlaySwitch(frame, true);
    frame[3] = flags;
    frame[4] = seconds;
    frame[5] = color.r;
    frame[6] = color.g;
    frame[7] = color.b;
}

/// The legacy E3 fields in the same order, without the magic; bytes 11-12 hold the FPS.
pub fn buildExValues(frame: *[frame_length]u8, values: Encoded) void {
    beginEx(frame, ex_opcode_set_values);
    frame[2] = values.temp;
    std.mem.writeInt(u16, frame[3..5], values.clock, .big);
    frame[5] = values.load;
    std.mem.writeInt(u16, frame[6..8], values.fan, .big);
    std.mem.writeInt(u16, frame[8..10], values.vram_clock, .big);
    frame[10] = values.vram;
    std.mem.writeInt(u16, frame[13..15], values.power, .big);
}

/// The color areas of the newer panel's built-in screens, Gigabyte's regions 101 to 105 in
/// order: the artwork (the eagle of screen 1, the helmet of screen 2, the left head of screen
/// 3), the label and the value of the readings, and the middle and right heads of screen 3.
pub const ex_area_count = 5;
const ExAreaRole = enum { logo, text };
const ex_area_roles = [ex_area_count]ExAreaRole{ .logo, .text, .text, .logo, .logo };

pub const ExAreaColor = struct { area: u8, color: Rgb };

/// The areas of built-in screen `screen` to color, in area order: the readings in `text_color`,
/// the artwork in `logo_color`. Null leaves those areas to the panel's own effect. Screens 1 and
/// 2 have the first three areas and screen 3 all five; the other screens get none, as in
/// Gigabyte's software.
pub fn exAreaColors(buffer: *[ex_area_count]ExAreaColor, screen: Mode, text_color: ?Rgb, logo_color: ?Rgb) []const ExAreaColor {
    const screen_areas: usize = switch (screen) {
        .faith1, .faith2 => 3,
        .faith3 => ex_area_count,
        else => 0,
    };
    var count: usize = 0;
    for (ex_area_roles[0..screen_areas], 0..) |role, area| {
        const color = switch (role) {
            .text => text_color,
            .logo => logo_color,
        } orelse continue;
        buffer[count] = .{ .area = @intCast(area), .color = color };
        count += 1;
    }
    return buffer[0..count];
}

/// A static color for one color area. rgbctrl never sends the LED save (`13 01`) or any other
/// save, so the panel keeps the color only until it loses power.
pub fn buildExAreaColor(frame: *[frame_length]u8, area: u8, color: Rgb) void {
    beginEx(frame, ex_opcode_set_area);
    frame[2] = ex_area_static;
    frame[3] = ex_area_speed;
    frame[4] = ex_area_brightness;
    frame[5] = color.r;
    frame[6] = color.g;
    frame[7] = color.b;
    frame[9] = area;
}

pub const ExVersion = struct { major: u8, minor: u8 };

/// `10 01 <major> <minor>`; Gigabyte's software takes a zero major version as no panel.
pub fn parseExFirmware(reply: []const u8) ?ExVersion {
    if (reply.len < 4 or reply[0] != ex_opcode_read_firmware or reply[1] != 0x01 or reply[2] == 0) return null;
    return .{ .major = reply[2], .minor = reply[3] };
}

pub const ExProbe = union(enum) {
    panel: ExVersion,
    /// Ask the older controller next, as Gigabyte's software does. A missing reply does not
    /// prove there is no newer controller, but the older one's query is read-only and harmless.
    fallback,
    /// Something answered that is not the newer controller: the LCD stays untouched.
    unclear,
};

/// Gigabyte's software takes a failed query and a zero major version as no newer controller.
/// Unlike it, rgbctrl leaves the card alone when a nonzero reply lacks the `10 01` echo.
pub fn classifyExProbe(result: sdk.nvapi.Exchange, reply: []const u8) ExProbe {
    switch (result) {
        .refused, .no_reply => return .fallback,
        .busy => return .unclear,
        .answered => {},
    }
    if (reply.len >= 3 and reply[2] == 0) return .fallback;
    if (parseExFirmware(reply)) |version| return .{ .panel = version };
    return .unclear;
}

pub const ExSetupStep = enum { open, set_mode, overlay_switch, overlay, area_colors };

/// The setup of the newer panel, in the order of Gigabyte's software. This panel cannot report
/// its screen or its colors, so what rgbctrl could not undo happens only when asked for:
/// switching it on and changing the screen when a screen was, and coloring areas when colors
/// were. The colors go last, once the overlay's label and value exist. The overlay alone is
/// switched off again on close.
pub fn exSetupSteps(change_screen: bool, set_colors: bool) []const ExSetupStep {
    if (change_screen and set_colors) return &.{ .open, .set_mode, .overlay_switch, .overlay, .area_colors };
    if (change_screen) return &.{ .open, .set_mode, .overlay_switch, .overlay };
    if (set_colors) return &.{ .overlay_switch, .overlay, .area_colors };
    return &.{ .overlay_switch, .overlay };
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
    buildExReadFirmware(&frame);
    try std.testing.expectEqualSlices(u8, &.{ 0x10, 0x01 }, frame[0..2]);
    try expectZeroTail(frame, 2);
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

test "newer panel commands are 256-byte frames with the opcode, 01 and zero padding" {
    var frame = [_]u8{0xAA} ** frame_length;
    buildExOpen(&frame, true);
    try std.testing.expectEqualSlices(u8, &.{ 0x15, 0x01, 0x01 }, frame[0..3]);
    try expectZeroTail(frame, 3);
    buildExOpen(&frame, false);
    try std.testing.expectEqualSlices(u8, &.{ 0x15, 0x01, 0x02 }, frame[0..3]);
    buildExSetMode(&frame, .faith2);
    try std.testing.expectEqualSlices(u8, &.{ 0x16, 0x01, 0x01 }, frame[0..3]);
    try expectZeroTail(frame, 3);
    buildExSetMode(&frame, .carousel);
    try std.testing.expectEqual(@as(u8, 7), frame[2]);
    buildExOverlaySwitch(&frame, false);
    try std.testing.expectEqualSlices(u8, &.{ 0x17, 0x01, 0x00 }, frame[0..3]);
    try expectZeroTail(frame, 3);
    buildExOverlaySwitch(&frame, true);
    try std.testing.expectEqualSlices(u8, &.{ 0x17, 0x01, 0x01 }, frame[0..3]);
    try expectZeroTail(frame, 3);
}

test "newer panel overlay carries the field bits, the seconds and the text color" {
    var frame = [_]u8{0xAA} ** frame_length;
    buildExOverlay(&frame, default_metrics, 4, .{ .r = 0x12, .g = 0x34, .b = 0x56 });
    try std.testing.expectEqualSlices(u8, &.{ 0x17, 0x01, 0x01, 0x8D, 0x04, 0x12, 0x34, 0x56 }, frame[0..8]);
    try expectZeroTail(frame, 8);
}

test "newer panel values match the packet of Gigabyte's service, fps left at zero" {
    var frame = [_]u8{0xAA} ** frame_length;
    buildExValues(&frame, .{ .temp = 55, .clock = 2400, .load = 37, .fan = 1200, .vram_clock = 15000, .vram = 20, .power = 250 });
    try std.testing.expectEqualSlices(u8, &.{ 0x23, 0x01, 0x37, 0x09, 0x60, 0x25, 0x04, 0xB0, 0x3A, 0x98, 0x14, 0x00, 0x00, 0x00, 0xFA }, frame[0..15]);
    try expectZeroTail(frame, 15);
}

test "newer panel firmware reply needs the echo and a major version" {
    try std.testing.expectEqual(@as(?ExVersion, .{ .major = 1, .minor = 5 }), parseExFirmware(&.{ 0x10, 0x01, 0x01, 0x05 }));
    try std.testing.expectEqual(@as(?ExVersion, null), parseExFirmware(&.{ 0x10, 0x01, 0x00, 0x05 }));
    try std.testing.expectEqual(@as(?ExVersion, null), parseExFirmware(&.{ 0x00, 0x00, 0x00, 0x00 }));
    try std.testing.expectEqual(@as(?ExVersion, null), parseExFirmware(&.{ 0xD6, 0x14, 0x01, 0x02 }));
    try std.testing.expectEqual(@as(?ExVersion, null), parseExFirmware(&.{ 0x10, 0x01, 0x01 }));
}

test "only a refusal, a missing reply or a zero version sends the probe on to the older panel" {
    const answered = sdk.nvapi.Exchange{ .answered = 1 };
    try std.testing.expectEqual(ExProbe{ .panel = .{ .major = 1, .minor = 5 } }, classifyExProbe(answered, &.{ 0x10, 0x01, 0x01, 0x05 }));
    try std.testing.expectEqual(ExProbe.fallback, classifyExProbe(.{ .refused = -1 }, &.{ 0, 0, 0, 0 }));
    try std.testing.expectEqual(ExProbe.fallback, classifyExProbe(.{ .no_reply = -1 }, &.{ 0, 0, 0, 0 }));
    try std.testing.expectEqual(ExProbe.fallback, classifyExProbe(answered, &.{ 0x10, 0x01, 0x00, 0x00 }));
    try std.testing.expectEqual(ExProbe.fallback, classifyExProbe(answered, &.{ 0x00, 0x00, 0x00, 0x00 }));
    try std.testing.expectEqual(ExProbe.unclear, classifyExProbe(answered, &.{ 0xD6, 0x14, 0x01, 0x02 }));
    try std.testing.expectEqual(ExProbe.unclear, classifyExProbe(.busy, &.{ 0, 0, 0, 0 }));
}

test "the newer panel keeps its power, screen and colors unless they were asked for" {
    const overlay_only = exSetupSteps(false, false);
    try std.testing.expectEqualSlices(ExSetupStep, &.{ .overlay_switch, .overlay }, overlay_only);
    for (overlay_only) |step| try std.testing.expect(step != .open and step != .set_mode and step != .area_colors);
    try std.testing.expectEqualSlices(ExSetupStep, &.{ .open, .set_mode, .overlay_switch, .overlay }, exSetupSteps(true, false));
    try std.testing.expectEqualSlices(ExSetupStep, &.{ .overlay_switch, .overlay, .area_colors }, exSetupSteps(false, true));
    try std.testing.expectEqualSlices(ExSetupStep, &.{ .open, .set_mode, .overlay_switch, .overlay, .area_colors }, exSetupSteps(true, true));
}

test "newer panel color areas get a static color at the speed and brightness Gigabyte starts with" {
    var frame = [_]u8{0xAA} ** frame_length;
    buildExAreaColor(&frame, 1, .{ .r = 0xFF, .g = 0xFF, .b = 0xFF });
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x01, 0x01, 0x06, 0x0A, 0xFF, 0xFF, 0xFF, 0x00, 0x01 }, frame[0..10]);
    try expectZeroTail(frame, 10);
    buildExAreaColor(&frame, 0, .{ .r = 0, .g = 0, .b = 0 });
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x01, 0x01, 0x06, 0x0A, 0x00, 0x00, 0x00, 0x00, 0x00 }, frame[0..10]);
    try expectZeroTail(frame, 10);
}

test "only the color areas of the chosen screen that were asked for get a color" {
    const white = Rgb{ .r = 0xFF, .g = 0xFF, .b = 0xFF };
    const black = Rgb{ .r = 0, .g = 0, .b = 0 };
    var buffer: [ex_area_count]ExAreaColor = undefined;
    try std.testing.expectEqual(@as(usize, 0), exAreaColors(&buffer, .faith1, null, null).len);
    try std.testing.expectEqualSlices(ExAreaColor, &.{ .{ .area = 1, .color = white }, .{ .area = 2, .color = white } }, exAreaColors(&buffer, .faith1, white, null));
    try std.testing.expectEqualSlices(ExAreaColor, &.{ .{ .area = 0, .color = black }, .{ .area = 1, .color = white }, .{ .area = 2, .color = white } }, exAreaColors(&buffer, .faith2, white, black));
    try std.testing.expectEqualSlices(ExAreaColor, &.{ .{ .area = 0, .color = black }, .{ .area = 3, .color = black }, .{ .area = 4, .color = black } }, exAreaColors(&buffer, .faith3, null, black));
    try std.testing.expectEqualSlices(ExAreaColor, &.{
        .{ .area = 0, .color = black },
        .{ .area = 1, .color = white },
        .{ .area = 2, .color = white },
        .{ .area = 3, .color = black },
        .{ .area = 4, .color = black },
    }, exAreaColors(&buffer, .faith3, white, black));
    try std.testing.expectEqual(@as(usize, 0), exAreaColors(&buffer, .chibi, white, black).len);
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
