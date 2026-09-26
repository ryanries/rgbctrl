const std = @import("std");
const Rgb = @import("abi.zig").Rgb;

pub const Hsv = struct {
    hue: u16,
    saturation: u8,
    value: u8,
};

pub const hue_range: u32 = 65536;

pub fn parseHex(text: []const u8) ?Rgb {
    const digits = if (text.len > 0 and text[0] == '#') text[1..] else text;
    if (digits.len != 6) return null;
    for (digits) |digit| {
        if (!std.ascii.isHex(digit)) return null;
    }
    const value = std.fmt.parseInt(u24, digits, 16) catch return null;
    return .{ .r = @truncate(value >> 16), .g = @truncate(value >> 8), .b = @truncate(value) };
}

pub fn toHsv(color: Rgb) Hsv {
    const max = @max(color.r, @max(color.g, color.b));
    const min = @min(color.r, @min(color.g, color.b));
    if (max == 0) return .{ .hue = 0, .saturation = 0, .value = 0 };
    const delta: i32 = @as(i32, max) - @as(i32, min);
    const max_value: i32 = max;
    const saturation: u8 = @intCast(@divTrunc(delta * 255 + @divTrunc(max_value, 2), max_value));
    if (delta == 0) return .{ .hue = 0, .saturation = saturation, .value = max };
    const r: i64 = color.r;
    const g: i64 = color.g;
    const b: i64 = color.b;
    const span: i64 = delta;
    const numerator: i64 = if (max == color.r)
        g - b
    else if (max == color.g)
        2 * span + (b - r)
    else
        4 * span + (r - g);
    const hue = @mod(@divFloor(numerator * hue_range, 6 * span), hue_range);
    return .{ .hue = @intCast(hue), .saturation = saturation, .value = max };
}

pub fn fromHsv(hsv: Hsv) Rgb {
    if (hsv.saturation == 0) return .{ .r = hsv.value, .g = hsv.value, .b = hsv.value };
    const scaled: u32 = @as(u32, hsv.hue) * 6;
    const sector = scaled >> 16;
    const fraction: u32 = scaled & 0xFFFF;
    const value: u32 = hsv.value;
    const saturation: u32 = hsv.saturation;
    const p: u8 = @intCast((value * (255 - saturation) + 127) / 255);
    const q: u8 = @intCast((value * (255 * 65536 - saturation * fraction) / 65536 + 127) / 255);
    const t: u8 = @intCast((value * (255 * 65536 - saturation * (65536 - fraction)) / 65536 + 127) / 255);
    const v: u8 = hsv.value;
    return switch (sector) {
        0 => .{ .r = v, .g = t, .b = p },
        1 => .{ .r = q, .g = v, .b = p },
        2 => .{ .r = p, .g = v, .b = t },
        3 => .{ .r = p, .g = q, .b = v },
        4 => .{ .r = t, .g = p, .b = v },
        else => .{ .r = v, .g = p, .b = q },
    };
}

pub fn scale(color: Rgb, numerator: u32, denominator: u32) Rgb {
    if (denominator == 0) return Rgb.black;
    return .{
        .r = @intCast(@min(255, (@as(u32, color.r) * numerator + denominator / 2) / denominator)),
        .g = @intCast(@min(255, (@as(u32, color.g) * numerator + denominator / 2) / denominator)),
        .b = @intCast(@min(255, (@as(u32, color.b) * numerator + denominator / 2) / denominator)),
    };
}

pub fn lerp(a: Rgb, b: Rgb, position: u16) Rgb {
    const t: u32 = position;
    const inverse: u32 = 65535 - t;
    return .{
        .r = @intCast((@as(u32, a.r) * inverse + @as(u32, b.r) * t + 32767) / 65535),
        .g = @intCast((@as(u32, a.g) * inverse + @as(u32, b.g) * t + 32767) / 65535),
        .b = @intCast((@as(u32, a.b) * inverse + @as(u32, b.b) * t + 32767) / 65535),
    };
}

pub fn hueByte(hue: u16) u8 {
    return @intCast((@as(u32, hue) * 256) >> 16);
}

test "parseHex accepts #RRGGBB and RRGGBB and rejects other lengths or digits" {
    try std.testing.expectEqual(Rgb{ .r = 0x12, .g = 0xAB, .b = 0xEF }, parseHex("#12abEF").?);
    try std.testing.expectEqual(Rgb{ .r = 0, .g = 0x80, .b = 0xFF }, parseHex("0080FF").?);
    try std.testing.expect(parseHex("#123") == null);
    try std.testing.expect(parseHex("#12345G") == null);
    try std.testing.expect(parseHex("#+12345") == null);
    try std.testing.expect(parseHex("#12_345") == null);
    try std.testing.expect(parseHex("") == null);
}

test "toHsv maps the primaries to the expected sixths of the hue wheel" {
    try std.testing.expectEqual(Hsv{ .hue = 0, .saturation = 255, .value = 255 }, toHsv(.{ .r = 255, .g = 0, .b = 0 }));
    try std.testing.expectEqual(@as(u16, 21845), toHsv(.{ .r = 0, .g = 255, .b = 0 }).hue);
    try std.testing.expectEqual(@as(u16, 43690), toHsv(.{ .r = 0, .g = 0, .b = 255 }).hue);
    try std.testing.expectEqual(Hsv{ .hue = 0, .saturation = 0, .value = 0 }, toHsv(Rgb.black));
    try std.testing.expectEqual(Hsv{ .hue = 0, .saturation = 0, .value = 255 }, toHsv(.{ .r = 255, .g = 255, .b = 255 }));
}

test "fromHsv round trips primaries and secondaries within one step" {
    const samples = [_]Rgb{
        .{ .r = 255, .g = 0, .b = 0 },
        .{ .r = 0, .g = 255, .b = 0 },
        .{ .r = 0, .g = 0, .b = 255 },
        .{ .r = 255, .g = 255, .b = 0 },
        .{ .r = 0, .g = 255, .b = 255 },
        .{ .r = 255, .g = 0, .b = 255 },
        .{ .r = 128, .g = 64, .b = 32 },
    };
    for (samples) |sample| {
        const back = fromHsv(toHsv(sample));
        try std.testing.expect(@abs(@as(i32, back.r) - sample.r) <= 1);
        try std.testing.expect(@abs(@as(i32, back.g) - sample.g) <= 1);
        try std.testing.expect(@abs(@as(i32, back.b) - sample.b) <= 1);
    }
}

test "scale applies a brightness fraction and zero brightness gives black" {
    try std.testing.expectEqual(Rgb{ .r = 128, .g = 64, .b = 0 }, scale(.{ .r = 255, .g = 128, .b = 0 }, 50, 100));
    try std.testing.expectEqual(Rgb.black, scale(.{ .r = 255, .g = 255, .b = 255 }, 0, 100));
}

test "lerp returns the endpoints at 0 and 65535" {
    const a = Rgb{ .r = 10, .g = 20, .b = 30 };
    const b = Rgb{ .r = 200, .g = 100, .b = 0 };
    try std.testing.expectEqual(a, lerp(a, b, 0));
    try std.testing.expectEqual(b, lerp(a, b, 65535));
}
