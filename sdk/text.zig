const std = @import("std");

pub const truncation_marker = "...";

pub fn print(buffer: []u8, comptime format: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buffer, format, args) catch {
        if (buffer.len < truncation_marker.len) return buffer[0..0];
        @memcpy(buffer[buffer.len - truncation_marker.len ..], truncation_marker);
        return buffer;
    };
}

pub fn roundToInt(comptime T: type, value: f64) T {
    const min: f64 = @floatFromInt(std.math.minInt(T));
    const max: f64 = @floatFromInt(std.math.maxInt(T));
    if (!(value == value)) return 0;
    if (value <= min) return std.math.minInt(T);
    if (value >= max) return std.math.maxInt(T);
    if (value >= 0) return @intFromFloat(value + 0.5);
    if (comptime @typeInfo(T).int.signedness == .unsigned) {
        return 0;
    } else {
        return -@as(T, @intFromFloat(-value + 0.5));
    }
}

pub fn fixed(buffer: []u8, value: f64, comptime decimals: u8) []const u8 {
    const scale: f64 = comptime blk: {
        var result: f64 = 1;
        for (0..decimals) |_| result *= 10;
        break :blk result;
    };
    const scaled = roundToInt(i64, value * scale);
    const negative = scaled < 0;
    const magnitude: u64 = @abs(scaled);
    const divisor: u64 = @intFromFloat(scale);
    const whole = magnitude / divisor;
    const fraction = magnitude % divisor;
    const sign: []const u8 = if (negative) "-" else "";
    if (decimals == 0) return print(buffer, "{s}{d}", .{ sign, whole });
    return print(buffer, "{s}{d}.{d:0>" ++ std.fmt.comptimePrint("{d}", .{decimals}) ++ "}", .{ sign, whole, fraction });
}

pub fn utf16ToUtf8(buffer: []u8, text: []const u16) []const u8 {
    var length: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        var code_point: u21 = text[index];
        index += 1;
        if (code_point >= 0xD800 and code_point <= 0xDBFF and index < text.len) {
            const low = text[index];
            if (low >= 0xDC00 and low <= 0xDFFF) {
                code_point = 0x10000 + ((code_point - 0xD800) << 10) + (low - 0xDC00);
                index += 1;
            }
        }
        if (code_point >= 0xD800 and code_point <= 0xDFFF) code_point = 0xFFFD;
        var encoded: [4]u8 = undefined;
        const encoded_length = std.unicode.utf8Encode(code_point, &encoded) catch 0;
        if (length + encoded_length > buffer.len) break;
        @memcpy(buffer[length .. length + encoded_length], encoded[0..encoded_length]);
        length += encoded_length;
    }
    return buffer[0..length];
}

pub fn utf8ToUtf16(buffer: []u16, text: []const u8) ?[:0]const u16 {
    if (buffer.len == 0) return null;
    const length = std.unicode.utf8ToUtf16Le(buffer[0 .. buffer.len - 1], text) catch return null;
    buffer[length] = 0;
    return buffer[0..length :0];
}

pub fn spanUtf16(text: [*:0]const u16) []const u16 {
    return std.mem.span(text);
}

pub fn hexBytes(buffer: []u8, bytes: []const u8) []const u8 {
    const digits = "0123456789ABCDEF";
    var length: usize = 0;
    for (bytes, 0..) |byte, index| {
        const needed: usize = if (index == 0) 2 else 3;
        if (length + needed > buffer.len) break;
        if (index != 0) {
            buffer[length] = ' ';
            length += 1;
        }
        buffer[length] = digits[byte >> 4];
        buffer[length + 1] = digits[byte & 0x0F];
        length += 2;
    }
    return buffer[0..length];
}

test "print truncates with a visible marker instead of failing" {
    var buffer: [8]u8 = undefined;
    const result = print(&buffer, "{s}", .{"0123456789"});
    try std.testing.expectEqualStrings("01234...", result);
}

test "roundToInt rounds half away from zero and clamps out of range values" {
    try std.testing.expectEqual(@as(i32, 3), roundToInt(i32, 2.5));
    try std.testing.expectEqual(@as(i32, -3), roundToInt(i32, -2.5));
    try std.testing.expectEqual(@as(i32, 2), roundToInt(i32, 2.49));
    try std.testing.expectEqual(@as(u8, 255), roundToInt(u8, 1000.0));
    try std.testing.expectEqual(@as(u8, 0), roundToInt(u8, -5.0));
}

test "fixed formats decimals without float formatting" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("65.0", fixed(&buffer, 65.0, 1));
    try std.testing.expectEqualStrings("-1.25", fixed(&buffer, -1.25, 2));
    try std.testing.expectEqualStrings("0.05", fixed(&buffer, 0.049, 2));
    try std.testing.expectEqualStrings("12", fixed(&buffer, 11.6, 0));
}

test "utf16ToUtf8 converts surrogate pairs and replaces lone surrogates" {
    var buffer: [32]u8 = undefined;
    const text = [_]u16{ 'C', ':', 0xD83D, 0xDE00, 0xD800 };
    try std.testing.expectEqualStrings("C:\u{1F600}\u{FFFD}", utf16ToUtf8(&buffer, &text));
}

test "hexBytes separates bytes with spaces and stops at the buffer end" {
    var buffer: [8]u8 = undefined;
    try std.testing.expectEqualStrings("10 68 01", hexBytes(&buffer, &.{ 0x10, 0x68, 0x01, 0x09 }));
}
