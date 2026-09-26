const std = @import("std");

pub const vendor_id: u16 = 0x3434;
pub const usage_page: u16 = 0xFF60;
pub const usage: u16 = 0x61;
pub const payload_length = 32;
pub const report_length = 33;
const report_id: u8 = 0x00;
pub const max_leds = 113;
pub const row_count = 6;
const column_count = 20;
pub const chunk_leds = 9;
pub const reply_timeout_ms: u32 = 250;
const quiesce_quiet_ms: u64 = 1000;
const quiesce_cap_ms: u64 = 5000;
pub const effect_delay_ms: u64 = 100;

const Product = struct {
    product_id: u16,
    led_count: u16,
    name: [:0]const u8,
};

const products = [_]Product{
    .{ .product_id = 0x0860, .led_count = 108, .name = "Keychron Q6 Max ANSI" },
    .{ .product_id = 0x0861, .led_count = 109, .name = "Keychron Q6 Max ISO" },
    .{ .product_id = 0x0862, .led_count = 113, .name = "Keychron Q6 Max JIS" },
    .{ .product_id = 0x0B60, .led_count = 108, .name = "Keychron Q6 HE ANSI" },
    .{ .product_id = 0x0B61, .led_count = 109, .name = "Keychron Q6 HE ISO" },
    .{ .product_id = 0x0B62, .led_count = 112, .name = "Keychron Q6 HE JIS" },
};

pub const ViaValue = enum(u8) {
    brightness = 0x01,
    effect = 0x02,
    speed = 0x03,
    color = 0x04,
};

pub const HardwareEffect = struct {
    effect: u8,
    brightness: u8,
    speed: u8,
    hue: u8,
    saturation: u8,
};

pub const LedColor = struct {
    hue: u8,
    saturation: u8,
    value: u8,

    pub fn eql(a: LedColor, b: LedColor) bool {
        return a.hue == b.hue and a.saturation == b.saturation and a.value == b.value;
    }
};

pub const IdPair = struct {
    vendor_id: u16,
    product_id: u16,
};

pub fn defaultLedCount(product_id: u16) ?u16 {
    for (products) |product| {
        if (product.product_id == product_id) return product.led_count;
    }
    return null;
}

pub fn productName(product_id: u16) [:0]const u8 {
    for (products) |product| {
        if (product.product_id == product_id) return product.name;
    }
    return "Keychron keyboard";
}

pub fn isDefaultProduct(product_id: u16) bool {
    return defaultLedCount(product_id) != null;
}

fn hexValue(character: u8) ?u4 {
    return switch (character) {
        '0'...'9' => @intCast(character - '0'),
        'a'...'f' => @intCast(character - 'a' + 10),
        'A'...'F' => @intCast(character - 'A' + 10),
        else => null,
    };
}

fn parseHexWord(text: []const u8) ?u16 {
    if (text.len != 4) return null;
    var value: u16 = 0;
    for (text) |character| {
        const digit = hexValue(character) orelse return null;
        value = (value << 4) | digit;
    }
    return value;
}

pub fn parseIdPair(text: []const u8) ?IdPair {
    if (text.len != 9 or text[4] != ':') return null;
    return .{
        .vendor_id = parseHexWord(text[0..4]) orelse return null,
        .product_id = parseHexWord(text[5..9]) orelse return null,
    };
}

fn clearReport(report: *[report_length]u8) []u8 {
    @memset(report, 0);
    report[0] = report_id;
    return report[1..report_length];
}

pub fn payloadFromReport(report: []const u8) ?[]const u8 {
    if (report.len != report_length or report[0] != report_id) return null;
    return report[1..report_length];
}

pub fn buildBasic(report: *[report_length]u8, command: u8) void {
    const payload = clearReport(report);
    payload[0] = command;
}

pub fn buildViaSet(report: *[report_length]u8, value: ViaValue, first: u8, second: u8) void {
    const payload = clearReport(report);
    payload[0] = 0x07;
    payload[1] = 0x03;
    payload[2] = @intFromEnum(value);
    payload[3] = first;
    if (value == .color) payload[4] = second;
}

pub fn buildViaGet(report: *[report_length]u8, value: ViaValue) void {
    const payload = clearReport(report);
    payload[0] = 0x08;
    payload[1] = 0x03;
    payload[2] = @intFromEnum(value);
}

pub fn buildViaSave(report: *[report_length]u8) void {
    const payload = clearReport(report);
    payload[0] = 0x09;
    payload[1] = 0x03;
}

pub fn buildA8(report: *[report_length]u8, subcommand: u8, arguments: []const u8) void {
    const payload = clearReport(report);
    payload[0] = 0xA8;
    payload[1] = subcommand;
    const count = @min(arguments.len, payload_length - 2);
    @memcpy(payload[2 .. 2 + count], arguments[0..count]);
}

pub fn buildLedRowRequest(report: *[report_length]u8, row: u8) void {
    buildA8(report, 0x06, &.{ row, 0xFF, 0xFF, 0xFF });
}

pub fn buildLedColorRequest(report: *[report_length]u8, start: u8, colors: []const LedColor) void {
    var arguments: [2 + chunk_leds * 3]u8 = undefined;
    arguments[0] = start;
    arguments[1] = @intCast(colors.len);
    for (colors, 0..) |color, index| {
        const offset = 2 + index * 3;
        arguments[offset] = color.hue;
        arguments[offset + 1] = color.saturation;
        arguments[offset + 2] = color.value;
    }
    buildA8(report, 0x0A, arguments[0 .. 2 + colors.len * 3]);
}

pub fn buildIndicatorsRequest(report: *[report_length]u8) void {
    buildA8(report, 0x04, &.{ 0x03, 0x00, 0x00, 0x80 });
}

pub fn percentToByte(value: u32) u8 {
    return @intCast(@min(value, @as(u32, 100)) * @as(u32, 255) / @as(u32, 100));
}

fn validLedRange(start: u8, count: u8, led_count: u16) bool {
    if (count == 0 or count > chunk_leds) return false;
    return @as(u16, start) + @as(u16, count) <= led_count;
}

const RequestKind = union(enum) {
    basic: u8,
    via_set: u8,
    via_get: u8,
    via_save,
    a8: u8,
};

fn requestKind(payload: []const u8) ?RequestKind {
    if (payload.len != payload_length) return null;
    return switch (payload[0]) {
        0x01, 0xA1, 0xA2 => .{ .basic = payload[0] },
        0x07 => if (payload[1] == 0x03) .{ .via_set = payload[2] } else null,
        0x08 => if (payload[1] == 0x03) .{ .via_get = payload[2] } else null,
        0x09 => if (payload[1] == 0x03) .via_save else null,
        0xA8 => .{ .a8 = payload[1] },
        else => null,
    };
}

const ReplyMatch = enum {
    unrelated,
    matched,
    unsupported,
    failed,
    duplicate,
};

pub const RequestMatcher = struct {
    kind: RequestKind,
    matched: bool = false,

    pub fn init(payload: []const u8) ?RequestMatcher {
        return .{ .kind = requestKind(payload) orelse return null };
    }

    pub fn observe(self: *RequestMatcher, response: []const u8) ReplyMatch {
        if (response.len != payload_length) return .unrelated;
        if (response[0] == 0xFF) return .unsupported;
        const is_match = switch (self.kind) {
            .basic => |command| response[0] == command,
            .via_set => |identifier| response[0] == 0x07 and response[1] == 0x03 and response[2] == identifier,
            .via_get => |identifier| response[0] == 0x08 and response[1] == 0x03 and response[2] == identifier,
            .via_save => response[0] == 0x09 and response[1] == 0x03,
            .a8 => |subcommand| response[0] == 0xA8 and response[1] == subcommand,
        };
        if (!is_match) return .unrelated;
        if (self.matched) return .duplicate;
        self.matched = true;
        if (self.kind == .a8 and response[2] != 0) return .failed;
        return .matched;
    }
};

pub fn a2RgbFlag(response: []const u8) ?bool {
    if (response.len != payload_length or response[0] != 0xA2) return null;
    return (response[2] & 0x80) != 0;
}

pub fn a8LedCount(response: []const u8) ?u16 {
    if (response.len != payload_length or response[0] != 0xA8 or response[1] != 0x05 or response[2] != 0) return null;
    const count: u16 = response[3];
    if (count == 0 or count > max_leds) return null;
    return count;
}

fn a8Row(response: []const u8) ?[]const u8 {
    if (response.len != payload_length or response[0] != 0xA8 or response[1] != 0x06 or response[2] != 0) return null;
    return response[3 .. 3 + column_count];
}

pub const LedMap = struct {
    led_count: u16,
    firmware_by_position: [max_leds]u8,
    led_x: [max_leds]u16,
};

pub const LedMapBuilder = struct {
    led_count: u16,
    firmware_by_position: [max_leds]u8 = [_]u8{0} ** max_leds,
    columns: [max_leds]u8 = [_]u8{0} ** max_leds,
    seen: [max_leds]bool = [_]bool{false} ** max_leds,
    position: u16 = 0,
    max_column: u8 = 0,

    pub fn init(led_count: u16) LedMapBuilder {
        return .{ .led_count = led_count };
    }

    pub fn appendRow(self: *LedMapBuilder, response: []const u8) !void {
        const row = a8Row(response) orelse return error.InvalidRow;
        for (row, 0..) |led_index, column| {
            if (led_index == 0xFF) continue;
            if (led_index >= self.led_count or led_index >= max_leds) return error.InvalidLedIndex;
            if (self.seen[led_index]) return error.DuplicateLedIndex;
            if (self.position >= self.led_count) return error.TooManyLeds;
            self.seen[led_index] = true;
            self.firmware_by_position[self.position] = led_index;
            self.columns[self.position] = @intCast(column);
            self.max_column = @max(self.max_column, @as(u8, @intCast(column)));
            self.position += 1;
        }
    }

    pub fn finish(self: *const LedMapBuilder) !LedMap {
        if (self.position != self.led_count) return error.MissingLeds;
        var map = LedMap{
            .led_count = self.led_count,
            .firmware_by_position = self.firmware_by_position,
            .led_x = [_]u16{0} ** max_leds,
        };
        for (0..self.led_count) |index| {
            map.led_x[index] = if (self.max_column == 0) 0 else @intCast(@as(u32, self.columns[index]) * 65535 / self.max_column);
        }
        return map;
    }
};

const QuiesceRelease = enum {
    none,
    quiet,
    cap,
};

pub const Quiesce = struct {
    active: bool = false,
    timed_out_at_ms: u64 = 0,
    last_report_ms: u64 = 0,
    cap_logged: bool = false,

    pub fn start(now_ms: u64) Quiesce {
        return .{ .active = true, .timed_out_at_ms = now_ms, .last_report_ms = now_ms };
    }

    pub fn observeReport(self: *Quiesce, now_ms: u64, report: []const u8) void {
        if (!self.active) return;
        if (report.len > 0 and report[0] == 0xA3) return;
        self.last_report_ms = now_ms;
    }

    pub fn release(self: *Quiesce, now_ms: u64) QuiesceRelease {
        if (!self.active) return .quiet;
        if (now_ms -| self.last_report_ms >= quiesce_quiet_ms) {
            self.active = false;
            return .quiet;
        }
        if (now_ms -| self.timed_out_at_ms >= quiesce_cap_ms) {
            self.active = false;
            self.cap_logged = true;
            return .cap;
        }
        return .none;
    }
};

pub const DiscoveryRestarts = struct {
    consecutive_failures: u8 = 0,

    pub fn recordFailure(self: *DiscoveryRestarts) bool {
        self.consecutive_failures += 1;
        return self.consecutive_failures >= 3;
    }

    pub fn recordSuccess(self: *DiscoveryRestarts) void {
        self.consecutive_failures = 0;
    }
};

test "extra id parser accepts four digit hex pairs and rejects malformed text" {
    try std.testing.expectEqual(IdPair{ .vendor_id = 0x3434, .product_id = 0x0860 }, parseIdPair("3434:0860").?);
    try std.testing.expectEqual(IdPair{ .vendor_id = 0xABCD, .product_id = 0x00EF }, parseIdPair("abcd:00eF").?);
    try std.testing.expect(parseIdPair("3434-0860") == null);
    try std.testing.expect(parseIdPair("343:0860") == null);
    try std.testing.expect(parseIdPair("3434:086G") == null);
}

test "built-in products cover the Q6 Max and Q6 HE and other ids fall back to a generic name" {
    try std.testing.expectEqual(@as(?u16, 108), defaultLedCount(0x0860));
    try std.testing.expectEqual(@as(?u16, 108), defaultLedCount(0x0B60));
    try std.testing.expectEqual(@as(?u16, 109), defaultLedCount(0x0B61));
    try std.testing.expectEqual(@as(?u16, 112), defaultLedCount(0x0B62));
    try std.testing.expectEqualStrings("Keychron Q6 HE ANSI", productName(0x0B60));
    try std.testing.expect(isDefaultProduct(0x0B62));
    try std.testing.expect(!isDefaultProduct(0x0B63));
    try std.testing.expectEqual(@as(?u16, null), defaultLedCount(0x0B63));
    try std.testing.expectEqualStrings("Keychron keyboard", productName(0x0B63));
}

test "packet builders produce exact raw HID reports" {
    var report: [report_length]u8 = undefined;
    buildViaSet(&report, .effect, 0x17, 0);
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x07, 0x03, 0x02, 0x17 }, report[0..5]);
    buildViaSet(&report, .color, 0x55, 0xAA);
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x07, 0x03, 0x04, 0x55, 0xAA }, report[0..6]);
    buildViaGet(&report, .speed);
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x08, 0x03, 0x03 }, report[0..4]);
    buildViaSave(&report);
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x09, 0x03 }, report[0..3]);
    buildLedRowRequest(&report, 5);
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0xA8, 0x06, 0x05, 0xFF, 0xFF, 0xFF }, report[0..7]);
}

test "A8 LED color packets carry up to nine HSV triplets" {
    var report: [report_length]u8 = undefined;
    const colors = [_]LedColor{
        .{ .hue = 1, .saturation = 2, .value = 3 },
        .{ .hue = 4, .saturation = 5, .value = 6 },
    };
    buildLedColorRequest(&report, 9, &colors);
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0xA8, 0x0A, 0x09, 0x02, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06 }, report[0..11]);
}

test "reply matcher accepts matching replies and detects unsupported failed and duplicate responses" {
    var request: [report_length]u8 = undefined;
    buildA8(&request, 0x01, &.{});
    var matcher = RequestMatcher.init(request[1..]).?;
    var response = [_]u8{0} ** payload_length;
    response[0] = 0xA8;
    response[1] = 0x01;
    response[2] = 0x00;
    try std.testing.expectEqual(ReplyMatch.matched, matcher.observe(&response));
    try std.testing.expectEqual(ReplyMatch.duplicate, matcher.observe(&response));
    var failed = response;
    failed[2] = 0x01;
    var failed_matcher = RequestMatcher.init(request[1..]).?;
    try std.testing.expectEqual(ReplyMatch.failed, failed_matcher.observe(&failed));
    var unsupported = [_]u8{0} ** payload_length;
    unsupported[0] = 0xFF;
    try std.testing.expectEqual(ReplyMatch.unsupported, failed_matcher.observe(&unsupported));
}

test "A2 parser reads the RGB support bit" {
    var response = [_]u8{0} ** payload_length;
    response[0] = 0xA2;
    response[2] = 0x80;
    try std.testing.expectEqual(true, a2RgbFlag(&response).?);
    response[2] = 0x7F;
    try std.testing.expectEqual(false, a2RgbFlag(&response).?);
}

test "LED map builder converts A8 row replies to row-major order and X positions" {
    var builder = LedMapBuilder.init(3);
    var response = [_]u8{0xFF} ** payload_length;
    response[0] = 0xA8;
    response[1] = 0x06;
    response[2] = 0;
    response[3] = 2;
    response[5] = 0;
    response[7] = 1;
    try builder.appendRow(&response);
    const map = try builder.finish();
    try std.testing.expectEqual(@as(u8, 2), map.firmware_by_position[0]);
    try std.testing.expectEqual(@as(u8, 0), map.firmware_by_position[1]);
    try std.testing.expectEqual(@as(u8, 1), map.firmware_by_position[2]);
    try std.testing.expectEqual(@as(u16, 0), map.led_x[0]);
    try std.testing.expectEqual(@as(u16, 32767), map.led_x[1]);
    try std.testing.expectEqual(@as(u16, 65535), map.led_x[2]);
}

test "LED map builder rejects duplicate out of range and incomplete rows" {
    var duplicate = LedMapBuilder.init(2);
    var response = [_]u8{0xFF} ** payload_length;
    response[0] = 0xA8;
    response[1] = 0x06;
    response[2] = 0;
    response[3] = 0;
    response[4] = 0;
    try std.testing.expectError(error.DuplicateLedIndex, duplicate.appendRow(&response));
    var out_of_range = LedMapBuilder.init(2);
    response[4] = 2;
    try std.testing.expectError(error.InvalidLedIndex, out_of_range.appendRow(&response));
    var incomplete = LedMapBuilder.init(2);
    response[3] = 0;
    response[4] = 0xFF;
    try incomplete.appendRow(&response);
    try std.testing.expectError(error.MissingLeds, incomplete.finish());
}

test "LED color range validation enforces firmware bounds" {
    try std.testing.expect(validLedRange(0, 9, 108));
    try std.testing.expect(validLedRange(99, 9, 108));
    try std.testing.expect(!validLedRange(100, 9, 108));
    try std.testing.expect(!validLedRange(0, 10, 108));
    try std.testing.expect(!validLedRange(0, 0, 108));
}

test "quiesce waits for quiet reports or the five second cap" {
    var quiet = Quiesce.start(1000);
    try std.testing.expectEqual(QuiesceRelease.none, quiet.release(1999));
    try std.testing.expectEqual(QuiesceRelease.quiet, quiet.release(2000));
    var flood = Quiesce.start(1000);
    var report = [_]u8{0} ** payload_length;
    report[0] = 0x07;
    flood.observeReport(1900, &report);
    flood.observeReport(2900, &report);
    flood.observeReport(3900, &report);
    flood.observeReport(4900, &report);
    flood.observeReport(5900, &report);
    try std.testing.expectEqual(QuiesceRelease.none, flood.release(4999));
    try std.testing.expectEqual(QuiesceRelease.cap, flood.release(6000));
}

test "A3 reports do not extend the quiesce window" {
    var quiesce = Quiesce.start(1000);
    var report = [_]u8{0} ** payload_length;
    report[0] = 0xA3;
    quiesce.observeReport(1500, &report);
    quiesce.observeReport(1900, &report);
    try std.testing.expectEqual(QuiesceRelease.quiet, quiesce.release(2000));
}

test "three failed discovery restarts marks the device lost and success resets the counter" {
    var restarts = DiscoveryRestarts{};
    try std.testing.expect(!restarts.recordFailure());
    try std.testing.expect(!restarts.recordFailure());
    restarts.recordSuccess();
    try std.testing.expect(!restarts.recordFailure());
    try std.testing.expect(!restarts.recordFailure());
    try std.testing.expect(restarts.recordFailure());
}

test "percent conversion follows the protocol floor mapping" {
    try std.testing.expectEqual(@as(u8, 0), percentToByte(0));
    try std.testing.expectEqual(@as(u8, 127), percentToByte(50));
    try std.testing.expectEqual(@as(u8, 252), percentToByte(99));
    try std.testing.expectEqual(@as(u8, 255), percentToByte(100));
}
