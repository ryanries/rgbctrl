const std = @import("std");
const sdk = @import("sdk");
const Rgb = sdk.abi.Rgb;

// The full-size SteelSeries Apex Pro from 2019 (model KB-00009). OpenRGB and SignalRGB both drive
// it on interface 1, HID collection 0xFFC0 / 0x01: colors as a 643-byte feature report, commands
// as 65-byte output reports with their replies in input reports, report id 0 throughout.
pub const vendor_id: u16 = 0x1038;
pub const apex_pro_product_id: u16 = 0x1610;
pub const interface_path_marker = "&mi_01";
pub const usage_page: u16 = 0xFFC0;
pub const usage: u16 = 0x0001;
pub const color_report_length = 643;
pub const command_report_length = 65;

const opcode_colors: u8 = 0x3A;
const opcode_firmware: u8 = 0x90;
const max_version_length = 32;

/// One key light: the id the firmware addresses it by (the key's USB HID usage, or 0xF0 and 0xFB
/// for two SteelSeries keys) and the key's horizontal center, in eighths of a key width from the
/// left edge of the board.
pub const Key = struct { id: u8, x8: u8 };

// 22.5 key widths: the main block, the navigation keys and the number pad with their gaps.
const board_width_x8: u32 = 180;

// Every key id of the Apex key library, in rows from the top left. A board lights the keys it
// has and ignores the others, so one table serves the US, ISO and Japanese layouts; the ISO and
// Japanese keys sit where those layouts have them.
const rows = [_][]const Key{
    &.{
        .{ .id = 0x29, .x8 = 4 }, // Esc
        .{ .id = 0x3A, .x8 = 20 }, // F1
        .{ .id = 0x3B, .x8 = 28 }, // F2
        .{ .id = 0x3C, .x8 = 36 }, // F3
        .{ .id = 0x3D, .x8 = 44 }, // F4
        .{ .id = 0x3E, .x8 = 56 }, // F5
        .{ .id = 0x3F, .x8 = 64 }, // F6
        .{ .id = 0x40, .x8 = 72 }, // F7
        .{ .id = 0x41, .x8 = 80 }, // F8
        .{ .id = 0x42, .x8 = 92 }, // F9
        .{ .id = 0x43, .x8 = 100 }, // F10
        .{ .id = 0x44, .x8 = 108 }, // F11
        .{ .id = 0x45, .x8 = 116 }, // F12
        .{ .id = 0x46, .x8 = 126 }, // Print Screen
        .{ .id = 0x47, .x8 = 134 }, // Scroll Lock
        .{ .id = 0x48, .x8 = 142 }, // Pause
        .{ .id = 0xFB, .x8 = 172 }, // media key, above the number pad
    },
    &.{
        .{ .id = 0x35, .x8 = 4 }, // `
        .{ .id = 0x1E, .x8 = 12 }, // 1
        .{ .id = 0x1F, .x8 = 20 }, // 2
        .{ .id = 0x20, .x8 = 28 }, // 3
        .{ .id = 0x21, .x8 = 36 }, // 4
        .{ .id = 0x22, .x8 = 44 }, // 5
        .{ .id = 0x23, .x8 = 52 }, // 6
        .{ .id = 0x24, .x8 = 60 }, // 7
        .{ .id = 0x25, .x8 = 68 }, // 8
        .{ .id = 0x26, .x8 = 76 }, // 9
        .{ .id = 0x27, .x8 = 84 }, // 0
        .{ .id = 0x2D, .x8 = 92 }, // -
        .{ .id = 0x2E, .x8 = 100 }, // =
        .{ .id = 0x89, .x8 = 108 }, // Yen (Japanese)
        .{ .id = 0x2A, .x8 = 112 }, // Backspace
        .{ .id = 0x49, .x8 = 126 }, // Insert
        .{ .id = 0x4A, .x8 = 134 }, // Home
        .{ .id = 0x4B, .x8 = 142 }, // Page Up
        .{ .id = 0x53, .x8 = 152 }, // Num Lock
        .{ .id = 0x54, .x8 = 160 }, // Num /
        .{ .id = 0x55, .x8 = 168 }, // Num *
        .{ .id = 0x56, .x8 = 176 }, // Num -
    },
    &.{
        .{ .id = 0x2B, .x8 = 6 }, // Tab
        .{ .id = 0x14, .x8 = 16 }, // Q
        .{ .id = 0x1A, .x8 = 24 }, // W
        .{ .id = 0x08, .x8 = 32 }, // E
        .{ .id = 0x15, .x8 = 40 }, // R
        .{ .id = 0x17, .x8 = 48 }, // T
        .{ .id = 0x1C, .x8 = 56 }, // Y
        .{ .id = 0x18, .x8 = 64 }, // U
        .{ .id = 0x0C, .x8 = 72 }, // I
        .{ .id = 0x12, .x8 = 80 }, // O
        .{ .id = 0x13, .x8 = 88 }, // P
        .{ .id = 0x2F, .x8 = 96 }, // [
        .{ .id = 0x30, .x8 = 104 }, // ]
        .{ .id = 0x31, .x8 = 114 }, // \ (US)
        .{ .id = 0x4C, .x8 = 126 }, // Delete
        .{ .id = 0x4D, .x8 = 134 }, // End
        .{ .id = 0x4E, .x8 = 142 }, // Page Down
        .{ .id = 0x5F, .x8 = 152 }, // Num 7
        .{ .id = 0x60, .x8 = 160 }, // Num 8
        .{ .id = 0x61, .x8 = 168 }, // Num 9
        .{ .id = 0x57, .x8 = 176 }, // Num +
    },
    &.{
        .{ .id = 0x39, .x8 = 7 }, // Caps Lock
        .{ .id = 0x04, .x8 = 18 }, // A
        .{ .id = 0x16, .x8 = 26 }, // S
        .{ .id = 0x07, .x8 = 34 }, // D
        .{ .id = 0x09, .x8 = 42 }, // F
        .{ .id = 0x0A, .x8 = 50 }, // G
        .{ .id = 0x0B, .x8 = 58 }, // H
        .{ .id = 0x0D, .x8 = 66 }, // J
        .{ .id = 0x0E, .x8 = 74 }, // K
        .{ .id = 0x0F, .x8 = 82 }, // L
        .{ .id = 0x33, .x8 = 90 }, // ;
        .{ .id = 0x34, .x8 = 98 }, // '
        .{ .id = 0x32, .x8 = 106 }, // # (ISO)
        .{ .id = 0x28, .x8 = 111 }, // Enter
        .{ .id = 0x5C, .x8 = 152 }, // Num 4
        .{ .id = 0x5D, .x8 = 160 }, // Num 5
        .{ .id = 0x5E, .x8 = 168 }, // Num 6
    },
    &.{
        .{ .id = 0xE1, .x8 = 9 }, // Left Shift
        .{ .id = 0x64, .x8 = 14 }, // \ (ISO)
        .{ .id = 0x1D, .x8 = 22 }, // Z
        .{ .id = 0x1B, .x8 = 30 }, // X
        .{ .id = 0x06, .x8 = 38 }, // C
        .{ .id = 0x19, .x8 = 46 }, // V
        .{ .id = 0x05, .x8 = 54 }, // B
        .{ .id = 0x11, .x8 = 62 }, // N
        .{ .id = 0x10, .x8 = 70 }, // M
        .{ .id = 0x36, .x8 = 78 }, // ,
        .{ .id = 0x37, .x8 = 86 }, // .
        .{ .id = 0x38, .x8 = 94 }, // /
        .{ .id = 0x87, .x8 = 102 }, // Ro (Japanese)
        .{ .id = 0xE5, .x8 = 109 }, // Right Shift
        .{ .id = 0x52, .x8 = 134 }, // Up
        .{ .id = 0x59, .x8 = 152 }, // Num 1
        .{ .id = 0x5A, .x8 = 160 }, // Num 2
        .{ .id = 0x5B, .x8 = 168 }, // Num 3
        .{ .id = 0x58, .x8 = 176 }, // Num Enter
    },
    &.{
        .{ .id = 0xE0, .x8 = 5 }, // Left Ctrl
        .{ .id = 0xE3, .x8 = 15 }, // Left Windows
        .{ .id = 0xE2, .x8 = 25 }, // Left Alt
        .{ .id = 0x8B, .x8 = 35 }, // Muhenkan (Japanese)
        .{ .id = 0x2C, .x8 = 55 }, // Space
        .{ .id = 0x8A, .x8 = 65 }, // Henkan (Japanese)
        .{ .id = 0x88, .x8 = 75 }, // Kana (Japanese)
        .{ .id = 0xE6, .x8 = 85 }, // Right Alt
        .{ .id = 0xE7, .x8 = 95 }, // the first key between Right Alt and Right Ctrl
        .{ .id = 0xF0, .x8 = 105 }, // the second key between Right Alt and Right Ctrl
        .{ .id = 0xE4, .x8 = 115 }, // Right Ctrl
        .{ .id = 0x50, .x8 = 126 }, // Left
        .{ .id = 0x51, .x8 = 134 }, // Down
        .{ .id = 0x4F, .x8 = 142 }, // Right
        .{ .id = 0x62, .x8 = 156 }, // Num 0
        .{ .id = 0x63, .x8 = 168 }, // Num .
    },
};

pub const keys: [keyCount()]Key = blk: {
    var flat: [keyCount()]Key = undefined;
    var index: usize = 0;
    for (rows) |row| {
        for (row) |key| {
            flat[index] = key;
            index += 1;
        }
    }
    break :blk flat;
};

pub const key_count = keys.len;

/// Key positions on the host's 0..65535 scale, for spatial effects.
pub const led_x: [key_count]u16 = blk: {
    var positions: [key_count]u16 = undefined;
    for (keys, 0..) |key, index| positions[index] = @intCast((@as(u32, key.x8) * 65535 + board_width_x8 / 2) / board_width_x8);
    break :blk positions;
};

fn keyCount() usize {
    var count: usize = 0;
    for (rows) |row| count += row.len;
    return count;
}

comptime {
    std.debug.assert(3 + key_count * 4 <= color_report_length);
}

/// The lighting collection of an Apex Pro: its USB id on interface 1, the vendor usage, and the
/// report sizes the colors and commands need.
pub fn isLightingCollection(path: []const u16, info: sdk.hid.Info) bool {
    return info.vendor_id == vendor_id and info.product_id == apex_pro_product_id and
        sdk.hid.pathContains(path, interface_path_marker) and
        info.usage_page == usage_page and info.usage == usage and
        info.feature_length == color_report_length and info.output_length == command_report_length;
}

/// `00 3A <count>`, then the key id and R, G, B of every key, zero-padded to the report length.
pub fn buildColorReport(report: *[color_report_length]u8, colors: *const [key_count]Rgb) void {
    @memset(report, 0);
    report[1] = opcode_colors;
    report[2] = key_count;
    for (keys, colors, 0..) |key, color, index| {
        report[3 + index * 4 ..][0..4].* = .{ key.id, color.r, color.g, color.b };
    }
}

/// `00 90`: asks for the keyboard firmware version, which is read-only.
pub fn buildFirmwareQuery(report: *[command_report_length]u8) void {
    @memset(report, 0);
    report[1] = opcode_firmware;
}

/// The firmware version ("4.1.0") from an input report, after the report id and an echo of the
/// query that newer Apex models put first. Null for any other report.
pub fn parseFirmwareVersion(report: []const u8) ?[]const u8 {
    if (report.len < 2 or report[0] != 0) return null;
    var payload = report[1..];
    if (payload[0] == opcode_firmware) payload = payload[1..];
    var length: usize = 0;
    var dots: usize = 0;
    while (length < payload.len and length < max_version_length) : (length += 1) {
        const char = payload[length];
        if (char == '.') {
            dots += 1;
        } else if (char < '0' or char > '9') {
            break;
        }
    }
    const version = payload[0..length];
    if (dots == 0 or version[0] == '.' or version[version.len - 1] == '.') return null;
    return version;
}

test "only the vendor collection on interface 1 with the color and command reports is used" {
    const path = std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\HID#VID_1038&PID_1610&MI_01#8&2f5ac1b&0&0000#{4d1e55b2-f16f-11cf-88cb-001111000030}");
    const lighting = sdk.hid.Info{ .vendor_id = 0x1038, .product_id = 0x1610, .version = 0x0100, .usage_page = 0xFFC0, .usage = 0x0001, .input_length = 65, .output_length = 65, .feature_length = 643 };
    try std.testing.expect(isLightingCollection(path, lighting));
    var other = lighting;
    other.product_id = 0x1614;
    try std.testing.expect(!isLightingCollection(path, other));
    other = lighting;
    other.usage_page = 0x000C;
    try std.testing.expect(!isLightingCollection(path, other));
    other = lighting;
    other.feature_length = 513;
    try std.testing.expect(!isLightingCollection(path, other));
    other = lighting;
    other.output_length = 0;
    try std.testing.expect(!isLightingCollection(path, other));
    const keyboard_interface = std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\HID#VID_1038&PID_1610&MI_00#8&1c0de&0&0000#{4d1e55b2-f16f-11cf-88cb-001111000030}");
    try std.testing.expect(!isLightingCollection(keyboard_interface, lighting));
}

test "the key table holds every id of the Apex key library exactly once" {
    try std.testing.expectEqual(@as(usize, 112), key_count);
    var seen: [256]u8 = @splat(0);
    for (keys) |key| seen[key.id] += 1;
    var expected: [256]u8 = @splat(0);
    for (0x04..0x65) |id| expected[id] = 1;
    for (0x87..0x8C) |id| expected[id] = 1;
    for (0xE0..0xE8) |id| expected[id] = 1;
    expected[0xF0] = 1;
    expected[0xFB] = 1;
    try std.testing.expectEqualSlices(u8, &expected, &seen);
}

test "positions grow from left to right within every row and span the board" {
    var start: usize = 0;
    for (rows) |row| {
        for (1..row.len) |offset| {
            try std.testing.expect(led_x[start + offset] > led_x[start + offset - 1]);
        }
        start += row.len;
    }
    try std.testing.expectEqual(@as(u16, 1456), led_x[0]);
    try std.testing.expectEqual(@as(u16, 64079), led_x[38]);
    try std.testing.expectEqual(@as(u8, 0x56), keys[38].id);
}

test "the bottom row follows the Japanese layout: Henkan and Kana sit between Space and Right Alt" {
    const bottom = rows[rows.len - 1];
    var ids: [bottom.len]u8 = undefined;
    for (bottom, &ids) |key, *id| id.* = key.id;
    // Space, Henkan, Kana, Right Alt, the two keys between Right Alt and Right Ctrl, Right Ctrl.
    try std.testing.expectEqualSlices(u8, &.{ 0x2C, 0x8A, 0x88, 0xE6, 0xE7, 0xF0, 0xE4 }, ids[4..11]);
}

test "the color report carries the key id and color of every key, zero-padded" {
    var colors: [key_count]Rgb = @splat(Rgb.black);
    colors[0] = .{ .r = 0x11, .g = 0x22, .b = 0x33 };
    colors[key_count - 1] = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC };
    var report: [color_report_length]u8 = @splat(0xEE);
    buildColorReport(&report, &colors);
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x3A, 0x70 }, report[0..3]);
    try std.testing.expectEqualSlices(u8, &.{ 0x29, 0x11, 0x22, 0x33 }, report[3..7]);
    try std.testing.expectEqualSlices(u8, &.{ 0x3A, 0x00, 0x00, 0x00 }, report[7..11]);
    const last = 3 + (key_count - 1) * 4;
    try std.testing.expectEqualSlices(u8, &.{ 0x63, 0xAA, 0xBB, 0xCC }, report[last..][0..4]);
    for (report[last + 4 ..]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "the firmware query is 00 90 and zero padding" {
    var report: [command_report_length]u8 = @splat(0xEE);
    buildFirmwareQuery(&report);
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x90 }, report[0..2]);
    for (report[2..]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "the firmware version is read with or without the echoed opcode" {
    var reply: [command_report_length]u8 = @splat(0);
    @memcpy(reply[1..6], "4.1.0");
    try std.testing.expectEqualStrings("4.1.0", parseFirmwareVersion(&reply).?);
    @memset(&reply, 0);
    reply[1] = 0x90;
    @memcpy(reply[2..9], "1.19.12");
    try std.testing.expectEqualStrings("1.19.12", parseFirmwareVersion(&reply).?);
}

test "a report that is not a firmware version is ignored" {
    var reply: [command_report_length]u8 = @splat(0);
    try std.testing.expectEqual(@as(?[]const u8, null), parseFirmwareVersion(&reply));
    @memcpy(reply[1..4], "410");
    try std.testing.expectEqual(@as(?[]const u8, null), parseFirmwareVersion(&reply));
    @memcpy(reply[1..4], ".41");
    try std.testing.expectEqual(@as(?[]const u8, null), parseFirmwareVersion(&reply));
    reply[0] = 0x05;
    @memcpy(reply[1..6], "4.1.0");
    try std.testing.expectEqual(@as(?[]const u8, null), parseFirmwareVersion(&reply));
    try std.testing.expectEqual(@as(?[]const u8, null), parseFirmwareVersion(&.{0}));
}
