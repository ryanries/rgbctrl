const std = @import("std");
const formatting = @import("../diag/format.zig");
const sdk = @import("sdk");

const win32 = sdk.win32;

pub const max_sensors = 64;
const max_name_length = 31;
pub const stale_after_ms: u64 = 5000;

pub const Entry = struct {
    name_buffer: [max_name_length]u8 = undefined,
    name_len: u8 = 0,
    value: f64 = 0,
    timestamp_ms: u64 = 0,
    publisher: u16 = 0,

    pub fn name(self: *const Entry) []const u8 {
        return self.name_buffer[0..self.name_len];
    }
};

const Reading = struct {
    value: f64,
    age_ms: u64,
};

const SetOutcome = enum { stored, replaced_other_publisher, invalid_name, reserved_name, not_finite, table_full };

pub const standard_sources = [_]struct { name: []const u8, source: []const u8 }{
    .{ .name = "cpu.temp", .source = "amd_cpu" },
    .{ .name = "cpu.power", .source = "amd_cpu" },
    .{ .name = "cpu.load", .source = "windows_metrics" },
    .{ .name = "cpu.freq", .source = "windows_metrics" },
    .{ .name = "mem.load", .source = "windows_metrics" },
    .{ .name = "gpu.temp", .source = "nvidia_gpu" },
    .{ .name = "gpu.load", .source = "nvidia_gpu" },
    .{ .name = "gpu.power", .source = "nvidia_gpu" },
    .{ .name = "gpu.fan", .source = "nvidia_gpu" },
    .{ .name = "gpu.freq", .source = "nvidia_gpu" },
    .{ .name = "gpu.mem.freq", .source = "nvidia_gpu" },
    .{ .name = "gpu.mem.load", .source = "nvidia_gpu" },
};

fn isValidName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_length) return false;
    for (name) |char| {
        if (!(std.ascii.isLower(char) or std.ascii.isDigit(char) or char == '.' or char == '_')) return false;
    }
    return true;
}

fn isCcdTemperature(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "cpu.ccd") or !std.mem.endsWith(u8, name, ".temp")) return false;
    const digits = name["cpu.ccd".len .. name.len - ".temp".len];
    if (digits.len == 0 or digits.len > 2) return false;
    for (digits) |char| {
        if (!std.ascii.isDigit(char)) return false;
    }
    return true;
}

fn standardSource(name: []const u8) ?[]const u8 {
    for (standard_sources) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.source;
    }
    if (isCcdTemperature(name)) return "amd_cpu";
    if (std.mem.startsWith(u8, name, "cpu.") or std.mem.startsWith(u8, name, "mem.") or std.mem.startsWith(u8, name, "gpu.")) return "";
    return null;
}

fn mayPublish(plugin_name: []const u8, sensor_name: []const u8) bool {
    if (standardSource(sensor_name)) |source| return std.mem.eql(u8, source, plugin_name);
    return sensor_name.len > plugin_name.len and std.mem.startsWith(u8, sensor_name, plugin_name) and sensor_name[plugin_name.len] == '.';
}

pub const SensorTable = struct {
    lock: win32.SRWLOCK = .{},
    entries: [max_sensors]Entry = undefined,
    count: usize = 0,

    pub fn set(self: *SensorTable, publisher: u16, publisher_name: []const u8, name: []const u8, value: f64, now_ms: u64) SetOutcome {
        if (!isValidName(name)) return .invalid_name;
        if (!mayPublish(publisher_name, name)) return .reserved_name;
        if (!std.math.isFinite(value)) return .not_finite;
        win32.AcquireSRWLockExclusive(&self.lock);
        defer win32.ReleaseSRWLockExclusive(&self.lock);
        for (self.entries[0..self.count]) |*entry| {
            if (!std.mem.eql(u8, entry.name(), name)) continue;
            const other = entry.publisher != publisher;
            entry.value = value;
            entry.timestamp_ms = now_ms;
            entry.publisher = publisher;
            return if (other) .replaced_other_publisher else .stored;
        }
        if (self.count == max_sensors) return .table_full;
        var entry = &self.entries[self.count];
        entry.* = .{ .value = value, .timestamp_ms = now_ms, .publisher = publisher, .name_len = @intCast(name.len) };
        @memcpy(entry.name_buffer[0..name.len], name);
        self.count += 1;
        return .stored;
    }

    pub fn get(self: *SensorTable, name: []const u8, now_ms: u64) ?Reading {
        win32.AcquireSRWLockExclusive(&self.lock);
        defer win32.ReleaseSRWLockExclusive(&self.lock);
        for (self.entries[0..self.count]) |*entry| {
            if (std.mem.eql(u8, entry.name(), name)) return .{ .value = entry.value, .age_ms = now_ms -| entry.timestamp_ms };
        }
        return null;
    }

    pub fn snapshot(self: *SensorTable, out: []Entry) usize {
        win32.AcquireSRWLockExclusive(&self.lock);
        defer win32.ReleaseSRWLockExclusive(&self.lock);
        const count = @min(out.len, self.count);
        @memcpy(out[0..count], self.entries[0..count]);
        return count;
    }
};

const testing = std.testing;

test "sensor names use lowercase letters, digits, dots and underscores up to 31 bytes" {
    try testing.expect(isValidName("cpu.temp"));
    try testing.expect(isValidName("gigabyte_gpu.core_temp"));
    try testing.expect(!isValidName("CPU.temp"));
    try testing.expect(!isValidName("cpu temp"));
    try testing.expect(!isValidName(""));
    try testing.expect(!isValidName(&@as([32]u8, @splat('a'))));
}

test "standard names are reserved for their documented sources and others need the plugin prefix" {
    try testing.expect(mayPublish("amd_cpu", "cpu.temp"));
    try testing.expect(mayPublish("amd_cpu", "cpu.ccd0.temp"));
    try testing.expect(!mayPublish("keychron", "cpu.temp"));
    try testing.expect(mayPublish("windows_metrics", "mem.load"));
    try testing.expect(!mayPublish("windows_metrics", "cpu.temp"));
    try testing.expect(mayPublish("keychron", "keychron.battery"));
    try testing.expect(!mayPublish("keychron", "keychronx.battery"));
    try testing.expect(!mayPublish("keychron", "gpu.temp"));
    try testing.expect(!mayPublish("keychron", "cpu.fan"));
    try testing.expect(mayPublish("nvidia_gpu", "gpu.temp"));
    try testing.expect(mayPublish("nvidia_gpu", "gpu.mem.load"));
    try testing.expect(!mayPublish("nvidia_gpu", "gpu.hotspot"));
    try testing.expect(!mayPublish("gigabyte_gpu", "gpu.fan"));
}

test "the table stores, updates and ages readings and reports another publisher replacing a value" {
    var table = SensorTable{};
    try testing.expectEqual(SetOutcome.stored, table.set(1, "amd_cpu", "cpu.temp", 55, 1000));
    try testing.expectEqual(SetOutcome.stored, table.set(1, "amd_cpu", "cpu.temp", 56, 2000));
    const reading = table.get("cpu.temp", 2500).?;
    try testing.expectEqual(@as(f64, 56), reading.value);
    try testing.expectEqual(@as(u64, 500), reading.age_ms);
    try testing.expect(table.get("cpu.power", 2500) == null);
    try testing.expectEqual(SetOutcome.not_finite, table.set(1, "amd_cpu", "cpu.power", std.math.nan(f64), 0));
    try testing.expectEqual(SetOutcome.reserved_name, table.set(2, "keychron", "cpu.temp", 1, 0));
    try testing.expectEqual(SetOutcome.stored, table.set(2, "sidecar", "sidecar.value", 1, 0));
    try testing.expectEqual(SetOutcome.replaced_other_publisher, table.set(3, "sidecar", "sidecar.value", 2, 0));
}

test "the table holds at most 64 sensors" {
    var table = SensorTable{};
    var name_buffer: [16]u8 = undefined;
    for (0..max_sensors) |index| {
        const name = try formatting.bufPrint(&name_buffer, "p.s{d}", .{index});
        try testing.expectEqual(SetOutcome.stored, table.set(1, "p", name, 1, 0));
    }
    try testing.expectEqual(SetOutcome.table_full, table.set(1, "p", "p.extra", 1, 0));
}
