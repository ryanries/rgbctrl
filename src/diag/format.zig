const std = @import("std");
const sdk = @import("sdk");

const Arg = union(enum) {
    text: []const u8,
    signed: i64,
    unsigned: u64,
};

fn toArg(value: anytype) Arg {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .int => |info| {
            if (info.signedness == .signed) return .{ .signed = @intCast(value) };
            return .{ .unsigned = @intCast(value) };
        },
        .comptime_int => {
            if (value < 0) return .{ .signed = value };
            return .{ .unsigned = value };
        },
        .bool => return .{ .text = if (value) "true" else "false" },
        .@"enum" => return .{ .text = @tagName(value) },
        .pointer => |info| {
            if (info.size == .slice and info.child == u8) return .{ .text = value };
            if (info.size == .one) {
                switch (@typeInfo(info.child)) {
                    .array => |array| if (array.child == u8) return .{ .text = value },
                    else => {},
                }
            }
            if (info.size == .many and info.sentinel_ptr != null and info.child == u8) return .{ .text = std.mem.span(value) };
            @compileError("unsupported format argument type " ++ @typeName(T));
        },
        .optional => return if (value) |inner| toArg(inner) else .{ .text = "null" },
        else => @compileError("unsupported format argument type " ++ @typeName(T)),
    }
}

fn countPlaceholders(comptime format: []const u8) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (index < format.len) : (index += 1) {
        if (format[index] == '{') {
            if (index + 1 < format.len and format[index + 1] == '{') {
                index += 1;
                continue;
            }
            const close = std.mem.indexOfScalarPos(u8, format, index, '}') orelse @compileError("unterminated placeholder in format: " ++ format);
            const spec = format[index + 1 .. close];
            if (!isSupportedSpec(spec)) @compileError("unsupported placeholder {" ++ spec ++ "} in format: " ++ format);
            count += 1;
            index = close;
        } else if (format[index] == '}') {
            if (index + 1 < format.len and format[index + 1] == '}') {
                index += 1;
                continue;
            }
            @compileError("unmatched '}' in format: " ++ format);
        }
    }
    return count;
}

fn isSupportedSpec(spec: []const u8) bool {
    if (spec.len == 0) return true;
    if (spec.len == 1) return spec[0] == 's' or spec[0] == 'd' or spec[0] == 'x';
    if (spec.len >= 5 and (spec[0] == 'd' or spec[0] == 'x') and spec[1] == ':' and spec[2] == '0' and spec[3] == '>') {
        for (spec[4..]) |char| {
            if (!std.ascii.isDigit(char)) return false;
        }
        return true;
    }
    return false;
}

pub fn print(buffer: []u8, comptime format: []const u8, args: anytype) []const u8 {
    const field_names = @typeInfo(@TypeOf(args)).@"struct".field_names;
    comptime {
        if (countPlaceholders(format) != field_names.len) @compileError("format argument count mismatch: " ++ format);
    }
    var values: [field_names.len]Arg = undefined;
    inline for (field_names, 0..) |field_name, index| values[index] = toArg(@field(args, field_name));
    return render(buffer, format, &values);
}

pub fn allocPrint(allocator: std.mem.Allocator, comptime format: []const u8, args: anytype) error{OutOfMemory}![]u8 {
    var buffer: [2048]u8 = undefined;
    return allocator.dupe(u8, print(&buffer, format, args));
}

pub fn fixed(buffer: []u8, value: f64, comptime decimals: u8) []const u8 {
    const scale: f64 = comptime blk: {
        var result: f64 = 1;
        for (0..decimals) |_| result *= 10;
        break :blk result;
    };
    const divisor: u64 = @intFromFloat(scale);
    const scaled = sdk.text.roundToInt(i64, value * scale);
    const magnitude: u64 = @abs(scaled);
    const sign: []const u8 = if (scaled < 0) "-" else "";
    if (decimals == 0) return print(buffer, "{s}{d}", .{ sign, magnitude });
    return print(buffer, "{s}{d}.{d:0>" ++ std.fmt.comptimePrint("{d}", .{decimals}) ++ "}", .{ sign, magnitude / divisor, magnitude % divisor });
}

pub fn bufPrint(buffer: []u8, comptime format: []const u8, args: anytype) error{NoSpaceLeft}![]const u8 {
    const field_names = @typeInfo(@TypeOf(args)).@"struct".field_names;
    comptime {
        if (countPlaceholders(format) != field_names.len) @compileError("format argument count mismatch: " ++ format);
    }
    var values: [field_names.len]Arg = undefined;
    inline for (field_names, 0..) |field_name, index| values[index] = toArg(@field(args, field_name));
    var writer = Writer{ .buffer = buffer };
    renderInto(&writer, format, &values);
    if (writer.overflowed) return error.NoSpaceLeft;
    return buffer[0..writer.length];
}

const Writer = struct {
    buffer: []u8,
    length: usize = 0,
    overflowed: bool = false,

    fn byte(self: *Writer, value: u8) void {
        if (self.length >= self.buffer.len) {
            self.overflowed = true;
            return;
        }
        self.buffer[self.length] = value;
        self.length += 1;
    }

    fn bytes(self: *Writer, values: []const u8) void {
        for (values) |value| self.byte(value);
    }
};

const truncation_marker = "...";

fn render(buffer: []u8, format: []const u8, args: []const Arg) []const u8 {
    var writer = Writer{ .buffer = buffer };
    renderInto(&writer, format, args);
    if (writer.overflowed and buffer.len >= truncation_marker.len) {
        @memcpy(buffer[buffer.len - truncation_marker.len ..], truncation_marker);
        return buffer;
    }
    return buffer[0..writer.length];
}

fn renderInto(writer: *Writer, format: []const u8, args: []const Arg) void {
    var arg_index: usize = 0;
    var index: usize = 0;
    while (index < format.len) : (index += 1) {
        const char = format[index];
        if (char == '{' and index + 1 < format.len and format[index + 1] == '{') {
            writer.byte('{');
            index += 1;
        } else if (char == '}' and index + 1 < format.len and format[index + 1] == '}') {
            writer.byte('}');
            index += 1;
        } else if (char == '{') {
            const close = std.mem.indexOfScalarPos(u8, format, index, '}') orelse {
                writer.bytes(format[index..]);
                return;
            };
            const spec = format[index + 1 .. close];
            index = close;
            if (arg_index >= args.len) {
                writer.byte('?');
                continue;
            }
            writeArg(writer, spec, args[arg_index]);
            arg_index += 1;
        } else {
            writer.byte(char);
        }
    }
}

fn writeArg(writer: *Writer, spec: []const u8, arg: Arg) void {
    var base: u8 = 10;
    var width: usize = 0;
    if (spec.len > 0 and spec[0] == 'x') base = 16;
    if (spec.len >= 5) {
        for (spec[4..]) |char| width = width * 10 + (char - '0');
    }
    switch (arg) {
        .text => |text| writer.bytes(text),
        .signed => |value| {
            if (value < 0) writer.byte('-');
            writeUnsigned(writer, @abs(value), base, width);
        },
        .unsigned => |value| writeUnsigned(writer, value, base, width),
    }
}

fn writeUnsigned(writer: *Writer, value: u64, base: u8, width: usize) void {
    var digits: [20]u8 = undefined;
    var count: usize = 0;
    var remaining = value;
    while (true) {
        const digit: u8 = @intCast(remaining % base);
        digits[count] = if (digit < 10) '0' + digit else 'a' + digit - 10;
        count += 1;
        remaining /= base;
        if (remaining == 0) break;
    }
    var padding = width;
    while (padding > count) : (padding -= 1) writer.byte('0');
    while (count > 0) {
        count -= 1;
        writer.byte(digits[count]);
    }
}

const testing = std.testing;

test "print renders text, signed and unsigned integers, hex and zero padding" {
    var buffer: [128]u8 = undefined;
    const name: []const u8 = "argb1";
    try testing.expectEqualStrings("zone argb1: -5 / 42 / ff / 007 / {x}", print(&buffer, "zone {s}: {d} / {d} / {x} / {d:0>3} / {{x}}", .{ name, @as(i32, -5), @as(u8, 42), @as(u32, 255), @as(u16, 7) }));
    try testing.expectEqualStrings("true E_BUSY literal", print(&buffer, "{} {s} {s}", .{ true, "E_BUSY", "literal" }));
    try testing.expectEqualStrings("0 18446744073709551615", print(&buffer, "{d} {d}", .{ 0, std.math.maxInt(u64) }));
}

test "print truncates with a visible marker" {
    var buffer: [8]u8 = undefined;
    try testing.expectEqualStrings("01234...", print(&buffer, "{s}", .{"0123456789"}));
}

test "bufPrint reports overflow instead of truncating" {
    var buffer: [4]u8 = undefined;
    try testing.expectError(error.NoSpaceLeft, bufPrint(&buffer, "{s}", .{"12345"}));
    try testing.expectEqualStrings("12", try bufPrint(&buffer, "{d}", .{12}));
}

test "enum and optional arguments print their names" {
    var buffer: [64]u8 = undefined;
    const Level = enum { warn };
    const missing: ?[]const u8 = null;
    try testing.expectEqualStrings("warn null", print(&buffer, "{s} {s}", .{ Level.warn, missing }));
}

test "fixed renders decimals without float formatting" {
    var buffer: [32]u8 = undefined;
    try testing.expectEqualStrings("65.0", fixed(&buffer, 65.0, 1));
    try testing.expectEqualStrings("-1.25", fixed(&buffer, -1.25, 2));
    try testing.expectEqualStrings("0.05", fixed(&buffer, 0.049, 2));
    try testing.expectEqualStrings("12", fixed(&buffer, 11.6, 0));
}
