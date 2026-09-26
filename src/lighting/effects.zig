const std = @import("std");
const sdk = @import("sdk");
const Spec = @import("../config/lighting_config.zig").Spec;

const abi = sdk.abi;
const Rgb = abi.Rgb;
const color = sdk.color;

const period_table_ms = [_]u32{ 20000, 12000, 8000, 5500, 4000, 3200, 2400, 1800, 1200, 800, 500 };

const breathing_levels: [256]u8 = blk: {
    @setEvalBranchQuota(20000);
    var table: [256]u8 = undefined;
    for (&table, 0..) |*level, index| {
        const mirrored_index = if (index <= 128) index else 256 - index;
        const angle = 2.0 * std.math.pi * @as(f64, @floatFromInt(mirrored_index)) / 256.0;
        const intensity = (1.0 - @cos(angle)) / 2.0;
        level.* = @intFromFloat(@round(intensity * 255.0));
    }
    break :blk table;
};

fn periodMs(speed: u8) u32 {
    const clamped: u32 = @min(speed, 100);
    const index = clamped / 10;
    if (index == 10) return period_table_ms[10];
    const slow = period_table_ms[index];
    const fast = period_table_ms[index + 1];
    return slow - (slow - fast) * (clamped % 10) / 10;
}

fn phase(t_ms: u64, period_ms: u32) u16 {
    const period: u64 = @max(period_ms, 1);
    return @intCast(((t_ms % period) * 65536) / period);
}

pub fn isAnimated(effect: abi.Effect) bool {
    return switch (effect) {
        .breathing, .flash, .cycle, .rainbow => true,
        .off, .static, .gradient => false,
    };
}

fn ledPosition(index: usize, led_count: usize, led_x: ?[]const u16) u16 {
    if (led_x) |positions| {
        if (index < positions.len) return positions[index];
    }
    if (led_count <= 1) return 0;
    return @intCast(index * 65535 / (led_count - 1));
}

pub fn render(spec: *const Spec, led_x: ?[]const u16, t_ms: u64, out: []Rgb) void {
    const period = periodMs(spec.speed);
    const position_in_period = phase(t_ms, period);
    const colors = if (spec.colors.len == 0) &[_]Rgb{Rgb.black} else spec.colors;
    const cycle_index: usize = @intCast((t_ms / @max(period, 1)) % colors.len);
    const reversed = spec.reverse and spec.isSpatial();
    const mirror_positions = reversed and led_x != null and spec.effect != .static;
    switch (spec.effect) {
        .off => @memset(out, Rgb.black),
        .static => {
            for (out, 0..) |*led, index| {
                led.* = if (index < spec.led_colors.len) spec.led_colors[index] else colors[0];
            }
        },
        .gradient => {
            for (out, 0..) |*led, index| {
                var x = ledPosition(index, out.len, led_x);
                if (mirror_positions) x = 65535 - x;
                led.* = gradientAt(colors, x);
            }
        },
        .breathing => @memset(out, color.scale(colors[cycle_index], breathing_levels[position_in_period >> 8], 255)),
        .flash => @memset(out, if (position_in_period < 32768) colors[cycle_index] else Rgb.black),
        .cycle => @memset(out, cycleAt(colors, position_in_period)),
        .rainbow => {
            for (out, 0..) |*led, index| {
                var x = ledPosition(index, out.len, led_x);
                if (mirror_positions) x = 65535 - x;
                const hue: u16 = position_in_period +% x;
                led.* = color.fromHsv(.{ .hue = hue, .saturation = 255, .value = 255 });
            }
        },
    }
    if (reversed and !mirror_positions) std.mem.reverse(Rgb, out);
    if (spec.brightness < 100) {
        for (out) |*led| led.* = color.scale(led.*, spec.brightness, 100);
    }
}

fn gradientAt(colors: []const Rgb, x: u16) Rgb {
    if (colors.len == 1) return colors[0];
    const segments: u32 = @intCast(colors.len - 1);
    const scaled: u32 = @as(u32, x) * segments;
    const segment = @min(scaled / 65535, segments - 1);
    const within = scaled - segment * 65535;
    return color.lerp(colors[segment], colors[segment + 1], @intCast(within));
}

fn cycleAt(colors: []const Rgb, position: u16) Rgb {
    if (colors.len == 1) {
        const start = color.toHsv(colors[0]);
        return color.fromHsv(.{ .hue = start.hue +% position, .saturation = 255, .value = start.value });
    }
    const count: u32 = @intCast(colors.len);
    const scaled: u32 = @as(u32, position) * count;
    const segment = scaled >> 16;
    const within: u32 = scaled & 0xFFFF;
    const next = (segment + 1) % count;
    return color.lerp(colors[segment], colors[next], @intCast(within * 65535 / 65536));
}

const testing = std.testing;
const red = Rgb{ .r = 255, .g = 0, .b = 0 };
const green = Rgb{ .r = 0, .g = 255, .b = 0 };
const blue = Rgb{ .r = 0, .g = 0, .b = 255 };

test "periodMs follows the speed table and interpolates linearly between entries" {
    try testing.expectEqual(@as(u32, 20000), periodMs(0));
    try testing.expectEqual(@as(u32, 12000), periodMs(10));
    try testing.expectEqual(@as(u32, 3200), periodMs(50));
    try testing.expectEqual(@as(u32, 2800), periodMs(55));
    try testing.expectEqual(@as(u32, 500), periodMs(100));
    try testing.expectEqual(@as(u32, 16000), periodMs(5));
}

test "phase maps time within the period onto 0..65535" {
    try testing.expectEqual(@as(u16, 0), phase(0, 1000));
    try testing.expectEqual(@as(u16, 32768), phase(500, 1000));
    try testing.expectEqual(@as(u16, 0), phase(3000, 1000));
    try testing.expectEqual(@as(u16, 65470), phase(999, 1000));
}

test "the breathing table starts dark, peaks at half period and is symmetric" {
    try testing.expectEqual(@as(u8, 0), breathing_levels[0]);
    try testing.expectEqual(@as(u8, 255), breathing_levels[128]);
    for (1..128) |index| try testing.expectEqual(breathing_levels[index], breathing_levels[256 - index]);
    try testing.expect(breathing_levels[64] >= 127 and breathing_levels[64] <= 128);
    for (1..129) |index| try testing.expect(breathing_levels[index] >= breathing_levels[index - 1]);
}

test "static uses led_colors per LED and colors[0] beyond them, mirrored when reversed" {
    const led_colors = [_]Rgb{ red, green };
    const colors = [_]Rgb{blue};
    var spec = Spec{ .effect = .static, .colors = &colors, .led_colors = &led_colors };
    var frame: [4]Rgb = undefined;
    render(&spec, null, 0, &frame);
    try testing.expectEqual(red, frame[0]);
    try testing.expectEqual(green, frame[1]);
    try testing.expectEqual(blue, frame[3]);
    spec.reverse = true;
    render(&spec, null, 0, &frame);
    try testing.expectEqual(blue, frame[0]);
    try testing.expectEqual(green, frame[2]);
    try testing.expectEqual(red, frame[3]);
}

test "gradient spans the colors from the first to the last LED" {
    const colors = [_]Rgb{ red, green, blue };
    var spec = Spec{ .effect = .gradient, .colors = &colors };
    var frame: [5]Rgb = undefined;
    render(&spec, null, 0, &frame);
    try testing.expectEqual(red, frame[0]);
    try testing.expectEqual(green, frame[2]);
    try testing.expectEqual(blue, frame[4]);
    try testing.expectEqual(Rgb{ .r = 128, .g = 127, .b = 0 }, frame[1]);
    spec.reverse = true;
    render(&spec, null, 0, &frame);
    try testing.expectEqual(blue, frame[0]);
    try testing.expectEqual(red, frame[4]);
}

test "gradient and rainbow honor plugin-provided LED positions" {
    const colors = [_]Rgb{ red, blue };
    const positions = [_]u16{ 65535, 0 };
    const spec = Spec{ .effect = .gradient, .colors = &colors };
    var frame: [2]Rgb = undefined;
    render(&spec, &positions, 0, &frame);
    try testing.expectEqual(blue, frame[0]);
    try testing.expectEqual(red, frame[1]);
    const rainbow = Spec{ .effect = .rainbow };
    const rainbow_positions = [_]u16{ 21846, 0 };
    render(&rainbow, &rainbow_positions, 0, &frame);
    try testing.expectEqual(green, frame[0]);
    try testing.expectEqual(red, frame[1]);
}

test "reverse without positions is an exact mirror of the normal frame" {
    const colors = [_]Rgb{ red, blue };
    var spec = Spec{ .effect = .gradient, .colors = &colors };
    var normal: [3]Rgb = undefined;
    var reversed: [3]Rgb = undefined;
    render(&spec, null, 0, &normal);
    spec.reverse = true;
    render(&spec, null, 0, &reversed);
    for (0..normal.len) |index| try testing.expectEqual(normal[normal.len - 1 - index], reversed[index]);
    var rainbow = Spec{ .effect = .rainbow };
    var rainbow_normal: [7]Rgb = undefined;
    var rainbow_reversed: [7]Rgb = undefined;
    render(&rainbow, null, 1234, &rainbow_normal);
    rainbow.reverse = true;
    render(&rainbow, null, 1234, &rainbow_reversed);
    for (0..rainbow_normal.len) |index| try testing.expectEqual(rainbow_normal[rainbow_normal.len - 1 - index], rainbow_reversed[index]);
}

test "reverse with plugin positions mirrors the positions" {
    const rainbow = Spec{ .effect = .rainbow, .reverse = true };
    const positions = [_]u16{ 0, 43689 };
    var frame: [2]Rgb = undefined;
    render(&rainbow, &positions, 0, &frame);
    try testing.expectEqual(color.fromHsv(.{ .hue = 65535, .saturation = 255, .value = 255 }), frame[0]);
    try testing.expectEqual(green, frame[1]);
}

test "a white one-color cycle sweeps the hue wheel at full saturation" {
    const colors = [_]Rgb{.{ .r = 255, .g = 255, .b = 255 }};
    const spec = Spec{ .effect = .cycle, .colors = &colors, .speed = 0 };
    var frame: [1]Rgb = undefined;
    render(&spec, null, 0, &frame);
    try testing.expectEqual(red, frame[0]);
    render(&spec, null, 6667, &frame);
    try testing.expectEqual(green, frame[0]);
}

test "a single LED sits at position zero and brightness zero renders black" {
    try testing.expectEqual(@as(u16, 0), ledPosition(0, 1, null));
    try testing.expectEqual(@as(u16, 65535), ledPosition(4, 5, null));
    var spec = Spec{ .effect = .rainbow };
    var frame: [1]Rgb = undefined;
    render(&spec, null, 0, &frame);
    try testing.expectEqual(red, frame[0]);
    spec.brightness = 0;
    render(&spec, null, 0, &frame);
    try testing.expectEqual(Rgb.black, frame[0]);
}

test "zones rendered at the same host time show the same phase" {
    const spec = Spec{ .effect = .breathing, .speed = 70 };
    var first: [4]Rgb = undefined;
    var second: [9]Rgb = undefined;
    render(&spec, null, 987_654, &first);
    render(&spec, null, 987_654, &second);
    try testing.expectEqual(first[0], second[0]);
    try testing.expectEqual(first[3], second[8]);
}

test "breathing is dark at the start of a period and full at the middle" {
    const colors = [_]Rgb{red};
    const spec = Spec{ .effect = .breathing, .colors = &colors, .speed = 50 };
    var frame: [2]Rgb = undefined;
    render(&spec, null, 0, &frame);
    try testing.expectEqual(Rgb.black, frame[0]);
    render(&spec, null, 1600, &frame);
    try testing.expectEqual(red, frame[1]);
}

test "breathing and flash advance to the next color every period" {
    const colors = [_]Rgb{ red, green };
    const spec = Spec{ .effect = .flash, .colors = &colors, .speed = 100 };
    var frame: [1]Rgb = undefined;
    render(&spec, null, 0, &frame);
    try testing.expectEqual(red, frame[0]);
    render(&spec, null, 300, &frame);
    try testing.expectEqual(Rgb.black, frame[0]);
    render(&spec, null, 500, &frame);
    try testing.expectEqual(green, frame[0]);
}

test "cycle with one color sweeps the hue wheel from that color at full saturation" {
    const colors = [_]Rgb{.{ .r = 128, .g = 64, .b = 64 }};
    const spec = Spec{ .effect = .cycle, .colors = &colors, .speed = 100 };
    var frame: [1]Rgb = undefined;
    render(&spec, null, 0, &frame);
    try testing.expectEqual(Rgb{ .r = 128, .g = 0, .b = 0 }, frame[0]);
}

test "cycle with several colors blends consecutive colors across the period" {
    const colors = [_]Rgb{ red, blue };
    const spec = Spec{ .effect = .cycle, .colors = &colors, .speed = 100 };
    var frame: [1]Rgb = undefined;
    render(&spec, null, 0, &frame);
    try testing.expectEqual(red, frame[0]);
    render(&spec, null, 250, &frame);
    try testing.expectEqual(blue, frame[0]);
    render(&spec, null, 125, &frame);
    try testing.expectEqual(Rgb{ .r = 128, .g = 0, .b = 127 }, frame[0]);
}

test "rainbow starts at red on the first LED and spreads the wheel across the zone" {
    const spec = Spec{ .effect = .rainbow };
    var frame: [3]Rgb = undefined;
    render(&spec, null, 0, &frame);
    try testing.expectEqual(red, frame[0]);
    try testing.expectEqual(red, frame[2]);
    try testing.expectEqual(@as(u8, 0), frame[1].r);
}

test "brightness scales every channel and off renders black" {
    const colors = [_]Rgb{.{ .r = 200, .g = 100, .b = 50 }};
    var spec = Spec{ .effect = .static, .colors = &colors, .brightness = 50 };
    var frame: [1]Rgb = undefined;
    render(&spec, null, 0, &frame);
    try testing.expectEqual(Rgb{ .r = 100, .g = 50, .b = 25 }, frame[0]);
    spec.effect = .off;
    render(&spec, null, 0, &frame);
    try testing.expectEqual(Rgb.black, frame[0]);
}

test "only breathing, flash, cycle and rainbow need repeated frames" {
    try testing.expect(isAnimated(.rainbow));
    try testing.expect(isAnimated(.breathing));
    try testing.expect(!isAnimated(.static));
    try testing.expect(!isAnimated(.gradient));
    try testing.expect(!isAnimated(.off));
}
